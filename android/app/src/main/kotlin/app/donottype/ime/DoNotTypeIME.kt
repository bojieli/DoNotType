package app.donottype.ime

import app.donottype.PromptAssets
import app.donottype.Settings
import app.donottype.accessibility.ScreenReaderService
import app.donottype.audio.WavRecorder
import app.donottype.core.DictationService
import app.donottype.core.ScreenContext
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
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
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
    private lateinit var indicator: DictationIndicatorView

    /// True once the press has lasted long enough to count as a hold rather than a tap.
    private var pressBecameHold = false
    private var pressStartedAt = 0L
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private var holdRunnable: Runnable? = null
    private var levelRunnable: Runnable? = null

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
        stopLevelUpdates()
        holdRunnable?.let { handler.removeCallbacks(it) }
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
            setPadding(PAD_SIDE, PAD_TOP, PAD_SIDE, PAD_BOTTOM)
            setBackgroundColor(Color.parseColor("#111417"))
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            )

            // The keyboard window extends behind the navigation bar. A gesture pill is thin enough
            // to miss the button below it; a three-button bar is not, and covered the bottom half
            // of "Tap to talk" -- the only control this keyboard has.
            ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
                val nav = insets.getInsets(WindowInsetsCompat.Type.navigationBars())
                view.setPadding(PAD_SIDE, PAD_TOP, PAD_SIDE, PAD_BOTTOM + nav.bottom)
                insets
            }
        }

        statusLabel = TextView(this).apply {
            textSize = 14f
            setTextColor(Color.parseColor("#8A9BA8"))
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 28)
        }

        indicator = DictationIndicatorView(this)

        talkButton = Button(this).apply {
            textSize = 17f
            // Tap to toggle, hold to talk -- the same gesture the desktop hotkey uses, and for the
            // same reason. Hold-only forces you to keep a finger down for the length of a thought,
            // which is fine for a sentence and miserable for a paragraph; toggle-only means a
            // mis-tap leaves the microphone open. Supporting both costs one timer: if the button
            // is still down after HOLD_THRESHOLD_MS the gesture is a hold and release ends it,
            // otherwise it was a tap and recording continues until the next tap.
            setOnTouchListener { view, event ->
                when (event.action) {
                    MotionEvent.ACTION_DOWN -> {
                        view.performClick()
                        onPressDown()
                        true
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        onPressUp(cancelled = event.action == MotionEvent.ACTION_CANCEL)
                        true
                    }
                    else -> false
                }
            }
        }

        root.addView(statusLabel)
        root.addView(
            indicator,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 120),
        )
        root.addView(
            talkButton,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 180),
        )
        render()
        return root
    }

    // MARK: - Gestures

    /**
     * A press starts recording immediately either way -- waiting to find out whether it is a tap
     * or a hold would clip the first word, which is the one people say fastest.
     */
    private fun onPressDown() {
        if (state == State.TRANSCRIBING) return

        // A second tap while already recording ends it. This is the toggle half of the gesture.
        if (state == State.RECORDING && !pressBecameHold) {
            finishRecording()
            return
        }

        pressBecameHold = false
        pressStartedAt = System.currentTimeMillis()
        beginRecording()

        holdRunnable = Runnable { pressBecameHold = true }.also {
            handler.postDelayed(it, HOLD_THRESHOLD_MS)
        }
    }

    private fun onPressUp(cancelled: Boolean) {
        holdRunnable?.let { handler.removeCallbacks(it) }
        holdRunnable = null

        if (cancelled) {
            // A finger dragged off the button, or the system stealing the gesture. Discard rather
            // than transcribe: the user did not choose to end here.
            if (state == State.RECORDING) {
                recorder.cancel()
                pendingContext = null
                state = State.IDLE
            }
            pressBecameHold = false
            return
        }

        val heldFor = System.currentTimeMillis() - pressStartedAt
        if (heldFor >= HOLD_THRESHOLD_MS) {
            // It was a hold: releasing ends it, exactly as before.
            pressBecameHold = false
            finishRecording()
        } else {
            // It was a tap: recording stays on until the next tap.
            pressBecameHold = false
        }
    }

    private fun startLevelUpdates() {
        stopLevelUpdates()
        levelRunnable = object : Runnable {
            override fun run() {
                // peakAmplitude is a raw 16-bit peak; the divisor puts ordinary speech near the
                // top of the range rather than leaving the bars permanently short.
                indicator.level = (recorder.consumePeak() / 12_000f).coerceIn(0f, 1f)
                handler.postDelayed(this, 60)
            }
        }.also { handler.post(it) }
    }

    private fun stopLevelUpdates() {
        levelRunnable?.let { handler.removeCallbacks(it) }
        levelRunnable = null
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
                    "Tap to talk · screen grounding off"
                } else {
                    "Tap to talk, or hold"
                }
                talkButton.text = "Tap to talk"
                talkButton.isEnabled = true
                indicator.mode = DictationIndicatorView.Mode.IDLE
                stopLevelUpdates()
            }
            State.RECORDING -> {
                statusLabel.text = "Listening…"
                talkButton.text = "Tap to stop"
                talkButton.isEnabled = true
                indicator.mode = DictationIndicatorView.Mode.RECORDING
                startLevelUpdates()
            }
            State.TRANSCRIBING -> {
                // Named rather than left as a spinner: after you stop talking the wait is dead
                // time, and "Transcribing" tells you what is consuming it and that it will end.
                statusLabel.text = "Transcribing…"
                talkButton.text = "Working…"
                talkButton.isEnabled = false
                indicator.mode = DictationIndicatorView.Mode.TRANSCRIBING
                stopLevelUpdates()
            }
            State.ERROR -> {
                talkButton.text = "Tap to talk"
                talkButton.isEnabled = true
                indicator.mode = DictationIndicatorView.Mode.IDLE
                stopLevelUpdates()
            }
        }
    }

    private companion object {
        const val TAG = "DoNotTypeIME"

        const val PAD_SIDE = 48
        const val PAD_TOP = 56
        const val PAD_BOTTOM = 56

        /**
         * How long a press has to last before releasing it ends the recording.
         *
         * 350 ms: long enough that a deliberate tap never trips it, short enough that someone who
         * meant to hold does not get a surprise toggle. Matches the desktop hotkey.
         */
        const val HOLD_THRESHOLD_MS = 350L
    }
}
