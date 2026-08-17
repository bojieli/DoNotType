package app.donottype

import app.donottype.core.Fidelity
import app.donottype.core.LogLevel
import app.donottype.core.ProviderKind
import app.donottype.core.RetentionPolicy
import app.donottype.core.RewriteStyle
import app.donottype.core.TranscriptMode
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.Base64
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream

/** Version 1 of the same portable document used by the Swift and Windows clients. */
object SettingsTransfer {
    const val FORMAT = "app.donottype.settings"
    const val VERSION = 1
    const val MAXIMUM_BYTES = 1_048_576
    private const val QR_PREFIX = "DNT1:"
    private const val MAXIMUM_QR_ENVELOPE_BYTES = 16_384

    data class Parsed(
        val root: JSONObject,
        val selected: ProviderKind,
        val fidelity: Fidelity,
        val fallback: ProviderKind?,
        val fallbackAfterSeconds: Int,
        val retention: RetentionPolicy,
        val liveStyle: RewriteStyle?,
    )

    fun export(pretty: Boolean = true): String {
        val providers = JSONObject()
        ProviderKind.entries.forEach { kind ->
            providers.put(
                canonicalId(kind),
                JSONObject()
                    .put("model", Settings.modelFor(kind))
                    .put("apiKey", Settings.keyFor(kind) ?: JSONObject.NULL),
            )
        }
        val fallback = Settings.fallbackProvider?.let {
            JSONObject()
                .put("provider", canonicalId(it))
                .put("afterSeconds", Settings.fallbackAfterSeconds)
        }
        val root = JSONObject()
            .put("format", FORMAT)
            .put("version", VERSION)
            .put("selectedProvider", canonicalId(Settings.provider))
            .put("providers", providers)
            .put("fidelity", Settings.fidelity.id)
            .put("fallback", fallback ?: JSONObject.NULL)
            .put("retention", Settings.retention.id)
            .put("keepAudio", Settings.keepAudio)
            .put(
                "dictionary",
                JSONObject()
                    .put("manual", JSONArray(Settings.dictionaryTerms))
                    .put("learned", JSONArray(Settings.learnedDictionaryTerms))
                    .put("learnsFromEdits", Settings.learnDictionaryFromEdits),
            )
            .put(
                "android",
                JSONObject()
                    .put("liveStyle", Settings.liveStyle.id)
                    .put("groundingEnabled", Settings.groundingEnabled)
                    .put("keytermBiasing", Settings.keytermBiasing)
                    .put("blockedPackages", JSONArray(Settings.blockedPackages.toList().sorted()))
                    .put("logLevel", Settings.logLevel.id)
                    .put("logContent", Settings.logContent)
                    .put("fileMode", Settings.fileMode.id),
            )
        return if (pretty) root.toString(2) else root.toString()
    }

    fun parse(value: String): Parsed {
        require(value.toByteArray(Charsets.UTF_8).size <= MAXIMUM_BYTES) {
            "The settings document is larger than the 1 MB limit."
        }
        val root = runCatching { JSONObject(value) }.getOrElse {
            throw IllegalArgumentException("This is not valid settings JSON: ${it.message}")
        }
        require(root.optString("format") == FORMAT) {
            "This JSON is not a DoNotType settings document."
        }
        require(root.optInt("version", -1) == VERSION) {
            "Settings format version ${root.optInt("version", -1)} is not supported."
        }
        val selectedRaw = root.optString("selectedProvider")
        val selected = parseProvider(selectedRaw)
            ?: throw IllegalArgumentException("This version does not support provider “$selectedRaw”.")
        val providers = root.optJSONObject("providers")
            ?: throw IllegalArgumentException("Provider settings are missing.")
        require(providers.has(canonicalId(selected)) || providers.has(selected.id)) {
            "The selected provider is missing from the provider settings."
        }
        val selectedValues = providers.optJSONObject(canonicalId(selected))
            ?: providers.optJSONObject(selected.id)
        require(selectedValues?.optString("endpoint").isNullOrBlank()) {
            "Android does not support custom provider endpoints yet; clear the endpoint before importing."
        }
        val fidelityRaw = root.optString("fidelity")
        val fidelity = Fidelity.entries.firstOrNull { it.id == fidelityRaw }
            ?: throw IllegalArgumentException("Unsupported fidelity “$fidelityRaw”.")
        val retentionRaw = root.optString("retention")
        val retention = RetentionPolicy.entries.firstOrNull { it.id == retentionRaw }
            ?: throw IllegalArgumentException("Unsupported retention “$retentionRaw”.")

        val fallbackObject = root.optJSONObject("fallback")
        val fallbackRaw = fallbackObject?.optString("provider").orEmpty()
        val fallback = fallbackRaw.takeIf { it.isNotEmpty() }?.let {
            parseProvider(it)
                ?: throw IllegalArgumentException("Unsupported fallback provider “$it”.")
        }
        require(fallback == null || fallback != selected) {
            "The fallback provider cannot be the selected provider."
        }
        if (fallback != null) {
            require(providers.has(canonicalId(fallback)) || providers.has(fallback.id)) {
                "The fallback provider is missing from the provider settings."
            }
            val fallbackValues = providers.optJSONObject(canonicalId(fallback))
                ?: providers.optJSONObject(fallback.id)
            require(fallbackValues?.optString("endpoint").isNullOrBlank()) {
                "Android does not support custom fallback endpoints yet; clear the endpoint before importing."
            }
        }
        val delay = fallbackObject?.optDouble("afterSeconds", 8.0)?.takeIf { it.isFinite() }
            ?.toInt()?.coerceIn(1, 120) ?: 8

        val android = root.optJSONObject("android")
        val styleRaw = android?.optString("liveStyle").orEmpty()
        val style = styleRaw.takeIf { it.isNotEmpty() }?.let {
            RewriteStyle.from(it)
                ?: throw IllegalArgumentException("Unsupported live style “$it”.")
        }
        android?.optString("logLevel")?.takeIf { it.isNotEmpty() }?.let {
            require(LogLevel.from(it) != null) { "Unsupported log level “$it”." }
        }
        android?.optString("fileMode")?.takeIf { it.isNotEmpty() }?.let {
            require(TranscriptMode.from(it) != null) { "Unsupported file mode “$it”." }
        }

        val dictionary = root.optJSONObject("dictionary")
            ?: throw IllegalArgumentException("Dictionary settings are missing.")
        readStrings(dictionary.optJSONArray("manual"))
        readStrings(dictionary.optJSONArray("learned"))

        return Parsed(root, selected, fidelity, fallback, delay, retention, style)
    }

    /** Applies only after [parse] has validated every typed value, preventing partial imports. */
    fun apply(parsed: Parsed) {
        val root = parsed.root
        val providers = root.getJSONObject("providers")
        val names = providers.keys()
        while (names.hasNext()) {
            val raw = names.next()
            val kind = parseProvider(raw) ?: continue
            val provider = providers.optJSONObject(raw) ?: continue
            Settings.provider = kind
            Settings.model = provider.optString("model").trim().ifEmpty { kind.defaultModel }
            Settings.setKey(
                kind,
                provider.optString("apiKey").takeIf { !provider.isNull("apiKey") && it.isNotEmpty() },
            )
        }
        Settings.provider = parsed.selected
        Settings.fidelity = parsed.fidelity
        Settings.fallbackProvider = parsed.fallback
        Settings.fallbackAfterSeconds = parsed.fallbackAfterSeconds
        Settings.retention = parsed.retention
        Settings.keepAudio = root.optBoolean("keepAudio", false)

        val dictionary = root.getJSONObject("dictionary")
        Settings.dictionaryTerms = readStrings(dictionary.optJSONArray("manual"))
        Settings.learnedDictionaryTerms = readStrings(dictionary.optJSONArray("learned"))
        Settings.learnDictionaryFromEdits = dictionary.optBoolean("learnsFromEdits", false)

        root.optJSONObject("android")?.let { android ->
            parsed.liveStyle?.let { Settings.liveStyle = it }
            Settings.groundingEnabled = android.optBoolean(
                "groundingEnabled", Settings.groundingEnabled)
            Settings.keytermBiasing = android.optBoolean(
                "keytermBiasing", Settings.keytermBiasing)
            android.optJSONArray("blockedPackages")?.let {
                Settings.blockedPackages = readStrings(it).toSet()
            }
            LogLevel.from(android.optString("logLevel"))?.let { Settings.logLevel = it }
            Settings.logContent = android.optBoolean("logContent", Settings.logContent)
            TranscriptMode.from(android.optString("fileMode"))?.let { Settings.fileMode = it }
        }
    }

    fun parseAndApply(value: String) = apply(parse(value))

    /**
     * Compresses settings before QR generation. Raw JSON near QR's capacity is technically valid
     * but too dense to scan reliably from another screen. The prefix versions this QR-only
     * envelope; files and the editor continue to use ordinary portable JSON.
     */
    fun encodeQR(value: String): String {
        val compact = parse(value).root.toString().toByteArray(Charsets.UTF_8)
        val output = ByteArrayOutputStream()
        // Apple's NSData .zlib and .NET's DeflateStream use the raw DEFLATE stream carried by
        // DNT1. `nowrap = true` keeps Android byte-compatible with both.
        val deflater = Deflater(Deflater.BEST_COMPRESSION, true)
        try {
            DeflaterOutputStream(output, deflater).use { it.write(compact) }
        } finally {
            deflater.end()
        }
        val encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(output.toByteArray())
        return QR_PREFIX + encoded
    }

    /** Accepts both the compressed envelope and raw-JSON codes made by earlier releases. */
    fun decodeQR(value: String): String {
        if (!value.startsWith(QR_PREFIX)) return value
        require(value.toByteArray(Charsets.UTF_8).size <= MAXIMUM_QR_ENVELOPE_BYTES) {
            "The QR payload is too large."
        }
        val compressed = runCatching {
            Base64.getUrlDecoder().decode(value.removePrefix(QR_PREFIX))
        }.getOrElse { throw IllegalArgumentException("The QR payload is damaged.") }

        val output = ByteArrayOutputStream()
        val inflater = Inflater(true)
        try {
            runCatching {
                InflaterInputStream(ByteArrayInputStream(compressed), inflater).use { input ->
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                        require(output.size() <= MAXIMUM_BYTES) {
                            "The settings document is larger than the 1 MB limit."
                        }
                    }
                }
            }.getOrElse {
                if (it is IllegalArgumentException) throw it
                throw IllegalArgumentException("The QR payload is damaged.")
            }
        } finally {
            inflater.end()
        }
        return output.toString(Charsets.UTF_8.name())
    }

    private fun canonicalId(kind: ProviderKind): String =
        if (kind == ProviderKind.GEMINI) "google" else kind.id

    private fun parseProvider(value: String): ProviderKind? = when (value.trim().lowercase()) {
        "google", "gemini" -> ProviderKind.GEMINI
        else -> ProviderKind.entries.firstOrNull { it.id == value.trim().lowercase() }
    }

    private fun readStrings(values: JSONArray?): List<String> {
        if (values == null) return emptyList()
        return List(values.length()) { index -> values.getString(index) }
    }
}
