package app.donottype

import app.donottype.core.Fidelity
import app.donottype.core.ProviderKind
import app.donottype.core.RetentionPolicy
import app.donottype.core.RewriteStyle
import org.junit.Assert.assertEquals
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
}
