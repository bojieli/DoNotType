package app.donottype

import android.content.Context
import android.content.ClipData
import android.content.ClipboardManager
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import app.donottype.core.ContextEncoder
import app.donottype.core.DictationRecord
import app.donottype.core.InputPart
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Shows exactly what was sent with one dictation.
 *
 * This is the open-source answer to a competitor encrypting its captured context to a server key
 * you do not hold: if an app reads your screen, you should be able to read what it read.
 *
 * It renders the stored `ScreenContext` back through the real [ContextEncoder], so what appears
 * here is the text that actually went over the wire rather than a description of it. A view that
 * formatted the fields itself would drift from the encoder the moment either changed, and would be
 * reassuring rather than true.
 */
object ContextInspector {

    fun show(context: Context, record: DictationRecord) {
        val report = describe(record)

        AlertDialog.Builder(context)
            .setTitle("What was sent")
            .setMessage(report)
            .setPositiveButton("Done", null)
            // Copying matters more here than anywhere else in the app: this is the evidence
            // somebody attaches to a report about a transcript that came out wrong.
            .setNeutralButton("Copy") { _, _ ->
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("What was sent", report))
                Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
            }
            .show()
    }

    /**
     * The whole thing as text.
     *
     * One string rather than a built layout, and deliberately: what is on screen and what the copy
     * button produces are then the same by construction, so nobody can paste a report into an issue
     * that differs from what they were looking at.
     */
    internal fun describe(record: DictationRecord): String = buildString {
        val when_ = SimpleDateFormat("d MMM HH:mm", Locale.getDefault()).format(Date(record.createdAt))
        appendLine("$when_ · ${record.appName ?: "an unknown app"}")
        appendLine(record.model)

        val screen = record.context
        if (screen == null) {
            appendLine()
            appendLine(
                "No context was sent. Grounding was off, the app was on the blocklist, the " +
                    "accessibility service returned nothing, or this dictation predates contexts " +
                    "being stored.",
            )
        } else {
            appendLine("~${ContextEncoder().estimatedTokens(screen)} context tokens")
            ContextEncoder().encode(screen).forEachIndexed { index, part ->
                appendLine()
                when (part) {
                    is InputPart.Text -> {
                        appendLine("── Part ${index + 1} · text · ${part.text.length} characters")
                        appendLine(part.text)
                    }
                    is InputPart.Image -> appendLine(
                        "── Part ${index + 1} · screenshot · ${part.data.size / 1024} KB",
                    )
                    is InputPart.Audio -> Unit // described below
                }
            }
        }

        appendLine()
        appendLine("── Audio")
        appendLine(
            if (record.audioFileName == null) {
                "Not retained. Audio is kept only for dictations that still need retrying, " +
                    "unless \"Keep audio\" is on."
            } else {
                "Retained so this dictation can be retried."
            },
        )

        // Both versions, when a rewrite was applied. Seeing what changed is the point of storing
        // the verbatim transcript separately.
        appendLine()
        appendLine("── What you said")
        appendLine(record.text)
        record.styledText?.takeIf { it.isNotEmpty() }?.let { styled ->
            appendLine()
            appendLine("── What was inserted${record.mode?.let { " · $it" }.orEmpty()}")
            appendLine(styled)
        }
    }
}
