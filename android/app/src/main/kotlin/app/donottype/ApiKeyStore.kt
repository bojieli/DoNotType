package app.donottype

import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import app.donottype.core.Log
import java.io.IOException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Encrypts provider keys with a non-exportable key held by Android Keystore. */
internal class ApiKeyStore(private val preferences: SharedPreferences) {
    private val log = Log("settings")

    /**
     * Reads a key and migrates the old private-but-plaintext preference on first use.
     *
     * Migration is deliberately fail-open for the existing value: a temporarily unavailable
     * keystore must not strand a key the user already entrusted to the app. The plaintext remains
     * in place and the next process start retries the migration.
     */
    @Synchronized
    fun read(preferenceName: String): String? {
        val stored = preferences.getString(preferenceName, null)?.takeIf { it.isNotEmpty() }
            ?: return null
        if (stored.startsWith(PREFIX)) {
            return runCatching { decrypt(preferenceName, stored) }
                .onFailure { error ->
                    log.error(mapOf("detail" to (error.message ?: error.javaClass.simpleName))) {
                        "could not decrypt a stored API key"
                    }
                }
                .getOrNull()
        }

        runCatching {
            val protected = encrypt(preferenceName, stored)
            if (!preferences.edit().putString(preferenceName, protected).commit()) {
                throw IOException("the encrypted preference could not be committed")
            }
        }.onFailure { error ->
            log.warn(mapOf("detail" to (error.message ?: error.javaClass.simpleName))) {
                "could not migrate an API key to Android Keystore; will retry"
            }
        }
        return stored
    }

    /** Writes no plaintext fallback: a new secret is either protected or not persisted. */
    @Synchronized
    fun write(preferenceName: String, value: String?) {
        if (value.isNullOrEmpty()) {
            if (!preferences.edit().remove(preferenceName).commit()) {
                throw IOException("the cleared preference could not be committed")
            }
            return
        }

        val protected = encrypt(preferenceName, value)
        if (!preferences.edit().putString(preferenceName, protected).commit()) {
            throw IOException("the encrypted preference could not be committed")
        }
    }

    private fun encrypt(preferenceName: String, value: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        cipher.updateAAD(preferenceName.toByteArray(Charsets.UTF_8))
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return PREFIX + Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(ciphertext, Base64.NO_WRAP)
    }

    private fun decrypt(preferenceName: String, envelope: String): String {
        val parts = envelope.removePrefix(PREFIX).split(':', limit = 2)
        require(parts.size == 2) { "the encrypted key envelope is malformed" }
        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val ciphertext = Base64.decode(parts[1], Base64.NO_WRAP)
        require(iv.size == GCM_IV_BYTES) { "the encrypted key IV is malformed" }
        require(ciphertext.size >= GCM_TAG_BYTES) { "the encrypted key payload is malformed" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
        cipher.updateAAD(preferenceName.toByteArray(Charsets.UTF_8))
        return cipher.doFinal(ciphertext).toString(Charsets.UTF_8)
    }

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            generateKey()
        }
    }

    internal companion object {
        const val PREFIX = "android-keystore:v1:"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "app.donottype.api-keys.v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_IV_BYTES = 12
        private const val GCM_TAG_BYTES = 16
    }
}
