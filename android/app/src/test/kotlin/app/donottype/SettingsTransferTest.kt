package app.donottype

import app.donottype.core.ChineseScript
import app.donottype.core.Fidelity
import app.donottype.core.ProviderKind
import app.donottype.core.RetentionPolicy
import app.donottype.core.RewriteStyle
import app.donottype.core.TypographySpacing
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class SettingsTransferTest {
    private val valid = """
        {
          "format":"app.donottype.settings",
          "version":1,
          "selectedProvider":"google",
          "providers":{
            "google":{"model":"gemini-test","apiKey":"secret"},
            "xai":{"model":"grok-stt","apiKey":null}
          },
          "fidelity":"light",
          "fallback":{"provider":"xai","afterSeconds":8},
          "retention":"oneWeek",
          "keepAudio":false,
          "dictionary":{"manual":["DoNotType"],"learned":[],"learnsFromEdits":true},
          "iOS":{"liveStyle":"verbatim"}
        }
    """.trimIndent()

    @Test fun parsesAppleProviderNameAndCommonSettings() {
        val parsed = SettingsTransfer.parse(valid)
        assertEquals(ProviderKind.GEMINI, parsed.selected)
        assertEquals(ProviderKind.XAI, parsed.fallback)
        assertEquals(Fidelity.LIGHT, parsed.fidelity)
        assertEquals(RetentionPolicy.ONE_WEEK, parsed.retention)
        assertEquals(null, parsed.liveStyle)
        assertEquals(
            RewriteStyle.VERBATIM,
            SettingsTransfer.parse(valid.replace("\"iOS\"", "\"android\"")).liveStyle,
        )
    }

    /// A profile written before the typography block existed still imports; one that carries an
    /// unreadable value fails the whole document rather than being silently defaulted.
    @Test fun typographyIsOptionalButNeverSilentlyWrong() {
        assertEquals(null, SettingsTransfer.parse(valid).typography)

        val withBlock = valid.replace(
            "\"keepAudio\":false,",
            "\"keepAudio\":false," +
                "\"typography\":{\"spacing\":\"tight\",\"chineseScript\":\"traditional\"," +
                "\"formattingSample\":\"中文 English。\"},",
        )
        val parsed = SettingsTransfer.parse(withBlock)
        assertEquals(TypographySpacing.TIGHT, parsed.typography?.first)
        assertEquals(ChineseScript.TRADITIONAL, parsed.typography?.second)
        assertEquals("中文 English。", parsed.typography?.third)

        assertThrows(IllegalArgumentException::class.java) {
            SettingsTransfer.parse(withBlock.replace("\"tight\"", "\"nonsense\""))
        }
        assertThrows(IllegalArgumentException::class.java) {
            SettingsTransfer.parse(withBlock.replace("\"traditional\"", "\"cursive\""))
        }
    }

    @Test fun rejectsWrongFormatAndMissingProvider() {
        assertThrows(IllegalArgumentException::class.java) {
            SettingsTransfer.parse(valid.replace("app.donottype.settings", "other"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            SettingsTransfer.parse(valid.replace("\"google\":{", "\"missing\":{"))
        }
    }

    @Test fun rejectsUnsupportedVersionFallbackAndEndpoint() {
        assertThrows(IllegalArgumentException::class.java) {
            SettingsTransfer.parse(valid.replace("\"version\":1", "\"version\":2"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            SettingsTransfer.parse(
                valid.replace("\"provider\":\"xai\"", "\"provider\":\"google\"")
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            SettingsTransfer.parse(
                valid.replace(
                    "\"model\":\"gemini-test\"",
                    "\"model\":\"gemini-test\",\"endpoint\":\"https://example.test/v1\"",
                )
            )
        }
    }

    @Test fun rejectsDocumentsOverOneMiB() {
        val oversized = valid + " ".repeat(SettingsTransfer.MAXIMUM_BYTES)
        assertThrows(IllegalArgumentException::class.java) {
            SettingsTransfer.parse(oversized)
        }
    }

    @Test fun qrEnvelopeIsCompactAndBackwardsCompatible() {
        val encoded = SettingsTransfer.encodeQR(valid)

        assertTrue(encoded.startsWith("DNT1:"))
        assertTrue(encoded.toByteArray().size < valid.toByteArray().size)
        assertEquals(
            SettingsTransfer.parse(valid).root.toString(),
            SettingsTransfer.parse(SettingsTransfer.decodeQR(encoded)).root.toString(),
        )
        assertEquals(valid, SettingsTransfer.decodeQR(valid))
    }

    @Test fun qrEnvelopeRejectsDamagedData() {
        assertThrows(IllegalArgumentException::class.java) {
            SettingsTransfer.decodeQR("DNT1:not-compressed")
        }
    }
}
