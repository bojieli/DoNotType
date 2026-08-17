package app.donottype

import app.donottype.audio.AudioDecoder
import app.donottype.core.DictationService
import app.donottype.core.FileTranscriber
import app.donottype.core.TranscriptMode
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.ViewGroup
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
        statusLabel.text = ""
        refresh()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Settings.initialise(this)
        title = "Transcribe a recording"
        setContentView(buildLayout())
        refresh()
    }

    private fun buildLayout(): ScrollView {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(56, 64, 56, 96)
        }

        column.addView(heading("Transcribe a recording", 24f))
        column.addView(
            body(
                "${AudioDecoder.SUPPORTED_FORMATS}, and anything else this phone can play. " +
                    "Recordings over 90 seconds are split on silence and sent in parallel. The " +
                    "transcript is stored in History like a dictation; the recording stays where " +
                    "it is.",
            ),
        )

        fileLabel = body("No recording chosen").apply { setTypeface(null, Typeface.BOLD) }
        column.addView(fileLabel)
        column.addView(
            button("Choose a recording…") {
                // audio/* misses some voice-memo containers that report a video MIME type, so the
                // filter is broad and the decoder gives the honest error for anything it cannot
                // open.
                picker.launch(arrayOf("audio/*", "video/*", "application/octet-stream"))
            },
        )

        column.addView(sectionTitle("Produce"))
        modeSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@FileTranscriptionActivity,
                android.R.layout.simple_spinner_dropdown_item,
                TranscriptMode.ALL.map { it.label },
            )
            setSelection(TranscriptMode.ALL.indexOfFirst { it.id == Settings.fileMode.id }
                .coerceAtLeast(0))
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(parent: AdapterView<*>?, view: android.view.View?, position: Int, id: Long) {
                    Settings.fileMode = TranscriptMode.ALL[position]
                    refresh()
                }
                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }
        column.addView(modeSpinner)

        // Stated before the button is pressed rather than as an error afterwards: with a
        // recogniser selected, "summarise this" is not slow, it is impossible.
        modeNote = body("")
        column.addView(modeNote)

        transcribeButton = button("Transcribe") { start() }
        column.addView(transcribeButton)

        statusLabel = body("")
        column.addView(statusLabel)

        toggleButton = button("Show what was said") {
            showingVerbatim = !showingVerbatim
            refresh()
        }
        column.addView(toggleButton)

        resultView = TextView(this).apply {
            textSize = 14f
            setTextIsSelectable(true)
            setPadding(0, 16, 0, 16)
        }
        column.addView(resultView)

        column.addView(
            button("Copy") {
                val text = resultView.text.toString()
                if (text.isEmpty()) return@button
                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("transcript", text))
                Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show()
            },
        )

        return ScrollView(this).apply {
            addView(
                column,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
        }
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
                        statusLabel.text = when (progress) {
                            is FileTranscriber.Progress.Decoding -> "Reading the file…"
                            is FileTranscriber.Progress.Transcribing ->
                                if (progress.of > 1) {
                                    "Transcribing part ${progress.done} of ${progress.of}…"
                                } else {
                                    "Transcribing…"
                                }
                            is FileTranscriber.Progress.Deriving -> progress.mode.progressLabel
                        }
                    }
                },
            )
            running = false
            result.onSuccess {
                outcome = it
                showingVerbatim = false
                statusLabel.text = summarise(it)
            }.onFailure {
                statusLabel.text = it.message ?: "That did not work."
            }
            refresh()
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
    }

    /** The name the picker shows, so the screen and the history row agree with the user's file. */
    private fun displayName(uri: Uri): String? =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }

    private fun sectionTitle(text: String) = heading(text, 18f)

    private fun heading(text: String, size: Float) = TextView(this).apply {
        this.text = text
        textSize = size
        setTypeface(null, Typeface.BOLD)
        setPadding(0, 48, 0, 12)
    }

    private fun body(text: String) = TextView(this).apply {
        this.text = text
        textSize = 13f
        setPadding(0, 0, 0, 16)
    }

    private fun button(title: String, onClick: () -> Unit) = Button(this).apply {
        text = title
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        )
        setOnClickListener { onClick() }
    }
}
