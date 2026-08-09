package ai.pine19.donottype.ime

import ai.pine19.donottype.PromptAssets
import ai.pine19.donottype.Settings
import ai.pine19.donottype.accessibility.ScreenReaderService
import ai.pine19.donottype.audio.WavRecorder
import ai.pine19.donottype.core.DictationService
import ai.pine19.donottype.core.ScreenContext
import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Color
import android.inputmethodservice.InputMethodService
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The keyboard.
 *
 * Android's decisive advantage over iOS: an `InputMethodService` can hold RECORD_AUDIO and record
 * in its own process, so hearing the speech and inserting the text happen in one place with no
 * cross-process hop. On iOS the same feature needs the containing app, an App Group, and a
 * round trip.
 *
 * Press and hold to talk; release to transcribe and insert.
 */
class DoNotTypeIME : InputMethodService() {

    private enum class State { IDLE, RECORDING, TRANSCRIBING, ERROR }

    private val recorder = WavRecorder()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val service by lazy { DictationService(this) }

    private lateinit var statusLabel: TextView
    private lateinit var talkButton: Button

    private var state = State.IDLE
        set(value) {
            field = value
            render()
        }

    /** Captured at press, before focus can move. */
    private var pendingContext: ScreenContext? = null

    override fun onCreate() {
        super.onCreate()
        Settings.initialise(this)
    }

    override fun onDestroy() {
        scope.cancel()
        recorder.cancel()
        super.onDestroy()
    }

    override fun onStartInputView(info: android.view.inputmethod.EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        // Anything that failed while offline goes out when the keyboard next opens.
        scope.launch { withContext(Dispatchers.IO) { service.retryAll() } }
    }

    override fun onCreateInputView(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 56, 48, 56)
            setBackgroundColor(Color.parseColor("#111417"))
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            )
        }

        statusLabel = TextView(this).apply {
            textSize = 14f
            setTextColor(Color.parseColor("#8A9BA8"))
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 28)
        }

        talkButton = Button(this).apply {
            textSize = 17f
            setOnTouchListener { view, event ->
                when (event.action) {
                    MotionEvent.ACTION_DOWN -> { view.performClick(); beginRecording(); true }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { finishRecording(); true }
                    else -> false
                }
            }
        }

        root.addView(statusLabel)
        root.addView(
            talkButton,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 180),
        )
        render()
        return root
    }

    // MARK: - Dictation

    private fun beginRecording() {
        if (state != State.IDLE) return

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            // An IME cannot request a runtime permission itself; it has to be granted from the
            // settings activity, which is why onboarding sends the user there first.
            statusLabel.text = "Open DoNotType and grant microphone access"
            state = State.ERROR
            return
        }

        // Phase 1 equivalent: snapshot the screen at press, while the field being dictated into is
        // still the focused one.
        pendingContext = if (Settings.groundingEnabled) {
            ScreenReaderService.instance?.capture()
        } else {
            null
        }

        runCatching { recorder.start() }
            .onSuccess { state = State.RECORDING }
            .onFailure {
                Log.e(TAG, "could not start recording", it)
                statusLabel.text = it.message ?: "Could not start recording"
                state = State.ERROR
            }
    }

    private fun finishRecording() {
        if (state != State.RECORDING) return

        val wav = recorder.stop()
        val context = pendingContext
        pendingContext = null

        if (wav == null) {
            // A tap rather than a hold. Not worth an error.
            state = State.IDLE
            return
        }

        val key = Settings.apiKey
        if (key.isNullOrBlank()) {
            statusLabel.text = "Open DoNotType and add your API key"
            state = State.ERROR
            return
        }

        state = State.TRANSCRIBING
        scope.launch {
            val outcome = withContext(Dispatchers.IO) {
                service.transcribe(wav, context, context?.appName)
            }
            outcome.fold(
                onSuccess = { record ->
                    if (record.text.isNotEmpty()) {
                        currentInputConnection?.commitText(record.text, 1)
                    }
                    state = State.IDLE
                },
                onFailure = { error ->
                    Log.e(TAG, "transcription failed", error)
                    // The recording is stored, so this is recoverable rather than lost.
                    statusLabel.text = if (service.isTransient(error)) {
                        "Saved — retry from DoNotType when you are back online"
                    } else {
                        error.message ?: "Transcription failed"
                    }
                    state = State.ERROR
                },
            )
        }
    }

    private fun render() {
        if (!::statusLabel.isInitialized) return
        when (state) {
            State.IDLE -> {
                statusLabel.text = if (ScreenReaderService.instance == null) {
                    "Hold to talk · screen grounding off"
                } else {
                    "Hold to talk"
                }
                talkButton.text = "Hold to talk"
                talkButton.isEnabled = true
            }
            State.RECORDING -> {
                statusLabel.text = "Listening… release to transcribe"
                talkButton.text = "Release to send"
                talkButton.isEnabled = true
            }
            State.TRANSCRIBING -> {
                statusLabel.text = "Transcribing…"
                talkButton.text = "Working…"
                talkButton.isEnabled = false
            }
            State.ERROR -> {
                talkButton.text = "Hold to talk"
                talkButton.isEnabled = true
            }
        }
    }

    private companion object {
        const val TAG = "DoNotTypeIME"
    }
}
