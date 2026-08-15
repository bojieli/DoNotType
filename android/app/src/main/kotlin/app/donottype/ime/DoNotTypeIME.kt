package app.donottype.ime

import app.donottype.PromptAssets
import app.donottype.Settings
import app.donottype.accessibility.ScreenReaderService
import app.donottype.audio.WavRecorder
import app.donottype.SettingsActivity
import app.donottype.core.DictationService
import app.donottype.core.FailureAdvice
import app.donottype.core.Log as DntLog
import app.donottype.core.RewriteStyle
import app.donottype.core.ProviderKind
import app.donottype.core.ScreenContext
import android.Manifest
import android.content.Intent
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

    /** Everything the keyboard does, under the same category as the service it calls. */
    private val log = DntLog("dictate")


    private enum class State { IDLE, RECORDING, TRANSCRIBING, ERROR }

    private val recorder = WavRecorder()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val service by lazy { DictationService(this) }

    private lateinit var statusLabel: TextView
    private lateinit var styleRow: LinearLayout
    private val styleButtons = mutableMapOf<RewriteStyle, Button>()
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
        // The provider may have changed in the app since this keyboard was last shown, and with it
        // whether a rewrite is possible at all.
        refreshStyleRow()
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
            // Tapping it opens the app, when the app is where the problem gets fixed. A keyboard
            // cannot request a runtime permission or hold an API key, so every one of its dead ends
            // is "go to the app" — and telling somebody to go somewhere is not the same as taking
            // them there, especially on a phone where the app is behind a home-screen search.
            setOnClickListener { if (openAppOnTap) openTheApp() }
        }

        styleRow = buildStyleRow()
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
        root.addView(styleRow)
        root.addView(
            indicator,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 120),
        )
        root.addView(
            talkButton,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 180),
        )
        refreshStyleRow()
        render()
        return root
    }

    /**
     * The style chips: verbatim, or one of the rewrites.
     *
     * The desktop makes this choice with a second hotkey — which key you hold decides, before you
     * speak. A phone has no second key, so it is a chip, and the rule it preserves is the one that
     * matters: the choice is made *before* speaking. A menu between finishing a sentence and seeing
     * it appear would defeat the point of dictating.
     *
     * Hidden when the configured backend cannot rewrite text at all, because a control that cannot
     * work is worse than one that is not there.
     */
    private fun buildStyleRow(): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 20)
        }

        styleButtons.clear()
        for (style in RewriteStyle.entries) {
            val chip = Button(this).apply {
                text = styleChipLabel(style)
                textSize = 12f
                isAllCaps = false
                minWidth = 0
                minimumWidth = 0
                setPadding(24, 8, 24, 8)
                setOnClickListener {
                    Settings.liveStyle = style
                    log.info(mapOf("style" to style.id)) { "live style chosen" }
                    refreshStyleRow()
                }
            }
            styleButtons[style] = chip
            row.addView(
                chip,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply { marginEnd = 10 },
            )
        }
        return row
    }

    /** The chip's word, which is the style's own name rather than "rewrite". */
    private fun styleChipLabel(style: RewriteStyle): String = when (style) {
        RewriteStyle.VERBATIM -> "Verbatim"
        RewriteStyle.FORMAL -> "Formal"
        RewriteStyle.CONCISE -> "Concise"
        RewriteStyle.BULLETS -> "Bullets"
    }

    private fun refreshStyleRow() {
        if (!::styleRow.isInitialized) return

        // A recogniser has no text endpoint, so there is nothing a rewrite chip could do. Rather
        // than offering one that silently returns the verbatim transcript, the row goes away.
        val canRewrite = !Settings.provider.isSpeechRecognition ||
            ProviderKind.entries.any { !it.isSpeechRecognition && !Settings.keyFor(it).isNullOrBlank() }
        styleRow.visibility = if (canRewrite) View.VISIBLE else View.GONE
        if (!canRewrite) return

        val selected = Settings.liveStyle
        styleButtons.forEach { (style, chip) ->
            val active = style == selected
            chip.setTextColor(Color.parseColor(if (active) "#0B0F14" else "#8A9BA8"))
            chip.setBackgroundColor(Color.parseColor(if (active) "#7FB2FF" else "#1B2430"))
        }
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
            log.warn(
                mapOf("permission" to "RECORD_AUDIO"),
            ) { "cannot record: the microphone permission is not granted" }
            showFixInTheApp("Microphone access is off — tap here to grant it")
            state = State.ERROR
            return
        }

        log.info(
            mapOf(
                "provider" to Settings.provider.id,
                "model" to Settings.model,
                "fidelity" to Settings.fidelity.id,
                "grounding" to if (Settings.groundingEnabled) "on" else "off",
                "package" to (currentInputEditorInfo?.packageName ?: "?"),
            ),
        ) { "recording started" }

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
                showStatus(it.message ?: "Could not start recording")
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
            showFixInTheApp("No API key yet — tap here to add one")
            state = State.ERROR
            return
        }

        // Read at the moment the recording ends, not when the request returns: tapping a
        // different chip while a transcription is in flight must not change what it becomes.
        val style = Settings.liveStyle

        state = State.TRANSCRIBING
        scope.launch {
            val outcome = withContext(Dispatchers.IO) {
                service.transcribe(wav, context, context?.appName, style)
            }
            outcome.fold(
                onSuccess = { record ->
                    // The rewrite when there is one, the transcript when there is not.
                    val delivered = record.styledText ?: record.text
                    if (delivered.isNotEmpty()) {
                        currentInputConnection?.commitText(delivered, 1)
                    }
                    if (record.rewriteFailed) {
                        // The words landed either way, but somebody who chose Formal and got their
                        // own words back should be told that is what happened.
                        showStatus("Inserted — not rewritten")
                        state = State.ERROR
                    } else {
                        state = State.IDLE
                    }
                },
                onFailure = { error ->
                    Log.e(TAG, "transcription failed", error)
                    // What happened and what to do about it, rather than a generic reassurance
                    // or a raw exception. On a keyboard there is one line for it, which is why the
                    // advice is written to fit one.
                    showStatus(FailureAdvice.describe(error).message)
                    state = State.ERROR
                },
            )
        }
    }

    /// Whether tapping the status label should open the app. Only when it is showing something
    /// the app can fix, so an ordinary status line is not a surprise button.
    private var openAppOnTap = false

    /// Says what is wrong and makes the label the way to fix it.
    private fun showFixInTheApp(message: String) {
        statusLabel.text = message
        openAppOnTap = true
    }

    /// Every other status goes through here, so the label stops being a button the moment it stops
    /// showing something the app can fix. A status line that silently opens an app is worse than
    /// one that does nothing.
    private fun showStatus(message: String) {
        statusLabel.text = message
        openAppOnTap = false
    }

    private fun openTheApp() {
        log.info(mapOf("reason" to statusLabel.text.toString())) { "opening the app to fix it" }
        try {
            startActivity(
                Intent(this, SettingsActivity::class.java).apply {
                    // A keyboard has no task of its own to start an activity in.
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                },
            )
        } catch (error: Exception) {
            log.warn(mapOf("error" to (error.message ?: ""))) { "could not open the app" }
            statusLabel.text = "Open DoNotType from the home screen to fix this"
        }
    }

    private fun render() {
        if (!::statusLabel.isInitialized) return
        when (state) {
            State.IDLE -> {
                showStatus(
                    if (ScreenReaderService.instance == null) {
                        "Tap to talk · screen grounding off"
                    } else {
                        "Tap to talk, or hold"
                    },
                )
                talkButton.text = "Tap to talk"
                talkButton.isEnabled = true
                indicator.mode = DictationIndicatorView.Mode.IDLE
                stopLevelUpdates()
            }
            State.RECORDING -> {
                showStatus("Listening…")
                talkButton.text = "Tap to stop"
                talkButton.isEnabled = true
                indicator.mode = DictationIndicatorView.Mode.RECORDING
                startLevelUpdates()
            }
            State.TRANSCRIBING -> {
                // Named rather than left as a spinner: after you stop talking the wait is dead
                // time, and "Transcribing" tells you what is consuming it and that it will end.
                showStatus("Transcribing…")
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
