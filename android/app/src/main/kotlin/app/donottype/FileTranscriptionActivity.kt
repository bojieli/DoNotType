package app.donottype

import app.donottype.audio.AudioDecoder
import app.donottype.core.DictationService
import app.donottype.core.FileTranscriber
import app.donottype.core.TranscriptMode
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import app.donottype.ui.body
import app.donottype.ui.card
import app.donottype.ui.controlRow
import app.donottype.ui.primaryButton
import app.donottype.ui.screenScaffold
import app.donottype.ui.screenSubtitle
import app.donottype.ui.screenTitle
import app.donottype.ui.sectionFooter
import app.donottype.ui.sectionTitle
import app.donottype.ui.settingRow
import app.donottype.ui.textButton
import app.donottype.ui.themeColor
import app.donottype.ui.tonalButton
import kotlinx.coroutines.launch

/**
 * Transcribe a recording that already exists.
 *
 * The keyboard covers speech you are about to make. This covers the voice memo, the call recording
 * and the file someone sent you — the same pipeline, entered through the storage access framework
 * instead of a microphone, with the same three modes the desktop offers.
 *
 * Built in code like the rest of this app's screens: it is four controls and a text view, and a
 * layout file per section would be more indirection than the screen is worth.
 */
class FileTranscriptionActivity : AppCompatActivity() {

    private lateinit var fileLabel: TextView
    private lateinit var modeSpinner: Spinner
    private lateinit var modeNote: TextView
    private lateinit var statusLabel: TextView
    private lateinit var transcribeButton: Button
    private lateinit var toggleButton: Button
    private lateinit var resultView: TextView
    private lateinit var resultSection: LinearLayout

    private val service by lazy { DictationService(this) }
    private val transcriber by lazy { FileTranscriber(this, service) }

    private var pickedUri: Uri? = null
    private var pickedName: String? = null
    private var outcome: FileTranscriber.Outcome? = null
    private var showingVerbatim = false
    private var running = false

    private val picker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@registerForActivityResult
        pickedUri = uri
        pickedName = displayName(uri)
        outcome = null
        fileLabel.text = pickedName ?: "a recording"
        resultView.text = ""
        say("", isError = false)
        refresh()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Settings.initialise(this)
        title = "Transcribe a recording"
        setContentView(buildLayout())
        refresh()
    }

    private fun buildLayout(): ScrollView = screenScaffold { column ->
        column.addView(screenTitle("Transcribe a recording"))
        column.addView(
            screenSubtitle(
                "${AudioDecoder.SUPPORTED_FORMATS}, and anything else this phone can play. " +
                    "Recordings over 90 seconds are split on silence and sent in parallel. The " +
                    "transcript is stored in History like a dictation; the recording stays where " +
                    "it is.",
            ),
        )

        column.addView(sectionTitle("Recording"))
        column.addView(
            card(
                settingRow(
                    "Choose a recording…",
                    "A voice memo, a call, a file someone sent you.",
                ) {
                    // audio/* misses some voice-memo containers that report a video MIME type, so
                    // the filter is broad and the decoder gives the honest error for anything it
                    // cannot open.
                    picker.launch(arrayOf("audio/*", "video/*", "application/octet-stream"))
                },
            ),
        )
        fileLabel = sectionFooter("No recording chosen")
        column.addView(fileLabel)

        column.addView(sectionTitle("Produce"))
        // Read once, here: the list gains a translation only when a target language is set.
        val modes = TranscriptMode.allTranslatingInto(Settings.translateTo)
        modeSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@FileTranscriptionActivity,
                android.R.layout.simple_spinner_dropdown_item,
                modes.map { it.label },
            )
            setSelection(modes.indexOfFirst { it.id == Settings.fileMode.id }.coerceAtLeast(0))
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(parent: AdapterView<*>?, view: android.view.View?, position: Int, id: Long) {
                    Settings.fileMode = modes[position]
                    refresh()
                }
                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }
        column.addView(card(controlRow("Mode", modeSpinner)))

        // Stated before the button is pressed rather than as an error afterwards: with a
        // recogniser selected, "summarise this" is not slow, it is impossible.
        modeNote = sectionFooter("")
        column.addView(modeNote)

        transcribeButton = primaryButton("Transcribe") { start() }
        column.addView(transcribeButton)

        statusLabel = body("").apply { visibility = android.view.View.GONE }
        column.addView(statusLabel)

        toggleButton = textButton("Show what was said") {
            showingVerbatim = !showingVerbatim
            refresh()
        }
        column.addView(toggleButton)

        // Selectable and unlimited: the transcript is the thing the user came for, and a long one
        // that has been cut off is worse than no result at all.
        resultView = body("").apply { setTextIsSelectable(true) }
        // Title, result and Copy together, so an empty result is absent rather than a titled empty
        // box above a button with nothing to put on the clipboard.
        resultSection = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = android.view.View.GONE
            addView(sectionTitle("Result"))
            addView(card(controlRow(null, resultView)))
            addView(
                tonalButton("Copy") {
                    val text = resultView.text.toString()
                    if (text.isEmpty()) return@tonalButton
                    val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    clipboard.setPrimaryClip(ClipData.newPlainText("transcript", text))
                    Toast.makeText(this@FileTranscriptionActivity, "Copied", Toast.LENGTH_SHORT)
                        .show()
                },
            )
        }
        column.addView(resultSection)
    }

    private fun start() {
        if (Settings.apiKey.isNullOrBlank()) {
            Toast.makeText(this, "Add an API key in Settings first", Toast.LENGTH_LONG).show()
            return
        }
        val uri = pickedUri ?: run {
            Toast.makeText(this, "Choose a recording first", Toast.LENGTH_SHORT).show()
            return
        }
        if (running) return
        running = true
        outcome = null
        refresh()

        lifecycleScope.launch {
            val result = transcriber.transcribe(
                uri = uri,
                fileName = pickedName ?: "recording",
                mode = Settings.fileMode,
                onProgress = { progress ->
                    runOnUiThread {
                        say(
                            when (progress) {
                                is FileTranscriber.Progress.Decoding -> "Reading the file…"
                                is FileTranscriber.Progress.Transcribing ->
                                    if (progress.of > 1) {
                                        "Transcribing part ${progress.done} of ${progress.of}…"
                                    } else {
                                        "Transcribing…"
                                    }
                                is FileTranscriber.Progress.Deriving -> progress.mode.progressLabel
                            },
                            isError = false,
                        )
                    }
                },
            )
            running = false
            result.onSuccess {
                outcome = it
                showingVerbatim = false
                say(summarise(it), isError = false)
            }.onFailure {
                // In full and in the error colour. These messages are FailureAdvice's own words,
                // written to be acted on, and clipping or greying one out defeats the point.
                say(it.message ?: "That did not work.", isError = true)
            }
            refresh()
        }
    }

    /** The one place the status line is written, so its colour never lags behind its text. */
    private fun say(text: String, isError: Boolean) {
        statusLabel.text = text
        statusLabel.setTextColor(
            themeColor(
                if (isError) {
                    androidx.appcompat.R.attr.colorError
                } else {
                    com.google.android.material.R.attr.colorOnSurfaceVariant
                },
            ),
        )
        statusLabel.visibility = if (text.isEmpty()) {
            android.view.View.GONE
        } else {
            android.view.View.VISIBLE
        }
    }

    private fun summarise(outcome: FileTranscriber.Outcome): String = buildList {
        if (outcome.durationSeconds > 0) {
            add("${outcome.durationSeconds.toInt()}s of audio in ${outcome.totalMillis / 1000.0}s")
        }
        if (outcome.chunkCount > 1) add("${outcome.chunkCount} parts")
        outcome.secondStageProvider?.let { add("$it wrote the result") }
    }.joinToString(" · ")

    private fun refresh() {
        val mode = Settings.fileMode
        val hasAPIKey = !Settings.apiKey.isNullOrBlank()
        transcribeButton.isEnabled = hasAPIKey && !running && pickedUri != null
        transcribeButton.text = if (running) "Transcribing…" else "Transcribe"

        modeNote.text = when {
            !hasAPIKey -> "Add and save an API key in DoNotType Settings before transcribing."
            !mode.needsSecondPass -> ""
            !transcriber.supports(mode) ->
                "${Settings.provider.id} is a speech recognition service: it cannot rewrite or " +
                    "summarise. Choose Verbatim, or add a key for Gemini or OpenRouter in Settings."
            Settings.provider.isSpeechRecognition ->
                "${Settings.provider.id} only transcribes, so the result will be written by " +
                    "${transcriber.secondStageBackend()?.id} in a second request."
            else -> ""
        }
        modeNote.visibility = if (modeNote.text.isEmpty()) {
            android.view.View.GONE
        } else {
            android.view.View.VISIBLE
        }

        // The verbatim transcript is always kept, so it is always one tap away — for a summary it
        // is the only way to see what was dropped.
        val produced = outcome
        val derived = produced != null &&
            produced.mode !is TranscriptMode.Verbatim &&
            produced.delivered != produced.verbatim
        toggleButton.visibility = if (derived) android.view.View.VISIBLE else android.view.View.GONE
        toggleButton.text = if (showingVerbatim) "Show the result" else "Show what was said"

        resultView.text = when {
            produced == null -> ""
            showingVerbatim -> produced.verbatim
            else -> produced.delivered
        }
        resultSection.visibility = if (resultView.text.isEmpty()) {
            android.view.View.GONE
        } else {
            android.view.View.VISIBLE
        }
    }

    /** The name the picker shows, so the screen and the history row agree with the user's file. */
    private fun displayName(uri: Uri): String? =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
}
