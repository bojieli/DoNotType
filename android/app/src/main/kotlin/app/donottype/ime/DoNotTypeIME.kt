package app.donottype.ime

import app.donottype.PromptAssets
import app.donottype.Settings
import app.donottype.accessibility.ScreenReaderService
import app.donottype.audio.WavRecorder
import app.donottype.SettingsActivity
import app.donottype.core.DictationService
import app.donottype.core.FailureAdvice
import app.donottype.core.NoSpeechException
import app.donottype.core.Log as DntLog
import app.donottype.core.LiveTranscriptionSession
import app.donottype.core.RewriteAvailability
import app.donottype.core.RewriteStyle
import app.donottype.core.ProviderFactory
import app.donottype.core.ProviderKind
import app.donottype.core.ProviderTransport
import app.donottype.core.PersonalDictionary
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
import android.view.inputmethod.ExtractedTextRequest
import android.view.inputmethod.EditorInfo
import android.text.InputType
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
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
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


    private enum class State { IDLE, RECORDING, TRANSCRIBING, NOTICE, ERROR }

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
    private var liveSession: LiveTranscriptionSession? = null

    /** Which field was focused when the key went down: its app, and the editor's id within it. */
    private var pendingTarget: Pair<String?, Int>? = null
    private var correctionWatch: Job? = null
    private var noticeJob: Job? = null
    private var pendingLifecycleNotice: String? = null
    private var lastLearnedTerms: List<String> = emptyList()

    private data class EditableSnapshot(
        val target: Pair<String?, Int>,
        val connectionIdentity: Int,
        val value: String,
        val selectionStart: Int,
        val selectionEnd: Int,
    )

    override fun onCreate() {
        super.onCreate()
        Settings.initialise(this)
    }

    override fun onDestroy() {
        scope.cancel()
        correctionWatch?.cancel()
        noticeJob?.cancel()
        stopLevelUpdates()
        holdRunnable?.let { handler.removeCallbacks(it) }
        recorder.cancel()
        recorder.onPcm = null
        liveSession?.cancel()
        super.onDestroy()
    }

    override fun onStartInputView(info: android.view.inputmethod.EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        correctionWatch?.cancel()
        // Anything that failed while offline goes out when the keyboard next opens.
        scope.launch { withContext(Dispatchers.IO) { service.retryAll() } }
        // The provider may have changed in the app since this keyboard was last shown, and with it
        // whether a rewrite is possible at all.
        refreshStyleRow()
        render()
        pendingLifecycleNotice?.let { message ->
            pendingLifecycleNotice = null
            showNotice(message)
        }
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        holdRunnable?.let { handler.removeCallbacks(it) }
        holdRunnable = null
        pressBecameHold = false

        if (state == State.RECORDING) {
            log.info { "recording stopped because the keyboard closed" }
            discardRecording()
            // The view is going away, so retain the explanation and show it when the keyboard next
            // opens instead of starting a three-second notice that expires while nobody can see it.
            pendingLifecycleNotice = "Recording stopped when the keyboard closed"
            state = State.IDLE
        }
        super.onFinishInputView(finishingInput)
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
            setOnClickListener {
                when {
                    undoLearningOnTap -> undoLastLearning()
                    openAppOnTap -> openTheApp()
                }
            }
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
                        onPressDown(event.eventTime)
                        true
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        onPressUp(
                            cancelled = event.action == MotionEvent.ACTION_CANCEL,
                            eventTime = event.eventTime,
                        )
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
                    // Kept clickable while unavailable rather than disabled: a disabled Button
                    // swallows the tap, and the tap is the only way a keyboard can ask "why is
                    // this greyed out". The answer goes to the status line.
                    val availability = RewriteAvailability.resolve(Settings.provider) {
                        !Settings.keyFor(it).isNullOrBlank()
                    }
                    if (style.isRewrite && !availability.isAvailable) {
                        availability.reason?.let { statusLabel.text = it }
                        log.info(mapOf("style" to style.id)) { "rewrite chip unavailable" }
                        return@setOnClickListener
                    }
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

        // Shown even when a rewrite cannot run, with the rewrite chips dimmed and unclickable.
        //
        // The row used to disappear, on the reasoning that a control which cannot work is worse
        // than one that is not there. It is not: a missing control cannot explain itself, and the
        // feature ended up looking absent rather than unavailable. A keyboard has no room for a
        // sentence, so tapping a dimmed chip puts the reason in the status line, which is the one
        // place on this surface that already carries explanations.
        val availability = RewriteAvailability.resolve(Settings.provider) {
            !Settings.keyFor(it).isNullOrBlank()
        }
        styleRow.visibility = View.VISIBLE

        // Verbatim is always reachable — it is what the main button does anyway, and leaving it
        // live means the row still reads as a choice rather than as a dead strip.
        val selected = if (availability.isAvailable) Settings.liveStyle else RewriteStyle.VERBATIM
        styleButtons.forEach { (style, chip) ->
            val usable = availability.isAvailable || !style.isRewrite
            val active = style == selected
            chip.setTextColor(
                Color.parseColor(
                    when {
                        !usable -> "#4A5560"
                        active -> "#0B0F14"
                        else -> "#8A9BA8"
                    }
                )
            )
            chip.setBackgroundColor(Color.parseColor(if (active) "#7FB2FF" else "#1B2430"))
        }
    }

    // MARK: - Gestures

    /**
     * A press starts recording immediately either way -- waiting to find out whether it is a tap
     * or a hold would clip the first word, which is the one people say fastest.
     */
    /**
     * Touch-down. [eventTime] is the touch's own timestamp, not the moment this ran: [beginRecording]
     * blocks the UI thread while the audio stack is built, and the release that arrives during that
     * work would otherwise measure as a hold and end a recording the user had only tapped to start.
     * Both ends of the measurement are on [MotionEvent.getEventTime]'s uptime clock, which is also
     * the one [handler] schedules on.
     */
    private fun onPressDown(eventTime: Long) {
        if (state == State.TRANSCRIBING) return

        // A second tap while already recording ends it. This is the toggle half of the gesture.
        if (state == State.RECORDING && !pressBecameHold) {
            finishRecording()
            return
        }

        pressBecameHold = false
        pressStartedAt = eventTime
        beginRecording()

        holdRunnable = Runnable { pressBecameHold = true }.also {
            handler.postDelayed(it, HOLD_THRESHOLD_MS)
        }
    }

    private fun onPressUp(cancelled: Boolean, eventTime: Long) {
        holdRunnable?.let { handler.removeCallbacks(it) }
        holdRunnable = null

        if (cancelled) {
            // A finger dragged off the button, or the system stealing the gesture. Discard rather
            // than transcribe: the user did not choose to end here.
            if (state == State.RECORDING) {
                discardRecording()
                state = State.IDLE
            }
            pressBecameHold = false
            return
        }

        val heldFor = eventTime - pressStartedAt
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
                // Collects whatever the capture thread has measured since the last pass. A bar is
                // 60 ms of audio, so this asks about twice as often as one can appear and never
                // has to interpolate.
                indicator.appendLevels(recorder.drainLevels())
                handler.postDelayed(this, 33)
            }
        }.also { handler.post(it) }
    }

    private fun stopLevelUpdates() {
        levelRunnable?.let { handler.removeCallbacks(it) }
        levelRunnable = null
    }

    /** Discards capture and every in-flight piece derived from it without changing the UI state. */
    private fun discardRecording() {
        recorder.cancel()
        recorder.onPcm = null
        liveSession?.cancel()
        liveSession = null
        pendingContext = null
        pendingTarget = null
        stopLevelUpdates()
    }

    // MARK: - Dictation

    /**
     * Opens the connection the dictation about to be recorded will need.
     *
     * Silent on failure by design: nothing has been asked for yet, so there is nothing to report.
     * A dead connection found here is replaced and the user never learns it happened.
     */
    private fun warmUpConnection() {
        val key = Settings.apiKey
        if (key.isNullOrBlank()) return
        scope.launch(Dispatchers.IO) {
            runCatching {
                ProviderFactory.create(Settings.provider, key, Settings.model).endpointOrigin
            }.getOrNull()?.let { ProviderTransport.warmUp(it) }
        }
    }

    /**
     * Puts the transcript on the clipboard when it must not be typed.
     *
     * The words have been recorded, sent and paid for by then, and the difference between "paste
     * it" and "nothing happened" is the difference between one gesture and an app that looks broken.
     */
    private fun copyForManualPaste(text: String) {
        runCatching {
            val clipboard = getSystemService(android.content.ClipboardManager::class.java)
            clipboard?.setPrimaryClip(
                android.content.ClipData.newPlainText("DoNotType transcript", text),
            )
        }
    }

    private fun beginRecording() {
        if (state == State.RECORDING || state == State.TRANSCRIBING) return
        // ERROR and NOTICE both render a live button. They must also accept it: previously ERROR
        // looked retryable but beginRecording silently rejected every tap until the IME reopened.
        noticeJob?.cancel()
        state = State.IDLE

        // Do not capture speech that cannot be sent. The keyboard points directly to the app so
        // the missing key is fixed before recording, rather than reported after the user talks.
        if (Settings.apiKey.isNullOrBlank()) {
            showFixInTheApp("No API key yet — tap here to add one")
            state = State.ERROR
            return
        }

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

        // Which field the words are meant for, decided now rather than when they arrive.
        pendingTarget = currentInputEditorInfo?.let { it.packageName to it.fieldId }

        // The same trick as the screen capture below, for the network. Opening a connection costs
        // about a second, and whether the pooled one is still alive cannot be known without using
        // it — so both happen here, against speech the user was going to produce anyway, rather
        // than after they stop with somebody watching. See ProviderTransport.
        warmUpConnection()

        // Phase 1 equivalent: snapshot the screen at press, while the field being dictated into is
        // still the focused one.
        val passwordField = currentInputEditorInfo?.let { isPasswordField(it.inputType) } == true
        pendingContext = if (Settings.groundingEnabled && !passwordField) {
            ScreenReaderService.instance?.capture()
        } else {
            null
        }

        liveSession = service.createLiveSession(pendingContext)
        recorder.onPcm = liveSession?.let { session -> { pcm -> session.append(pcm) } }

        runCatching { recorder.start() }
            .onSuccess { state = State.RECORDING }
            .onFailure {
                recorder.onPcm = null
                liveSession?.cancel()
                liveSession = null
                Log.e(TAG, "could not start recording", it)
                showStatus(it.message ?: "Could not start recording")
                state = State.ERROR
            }
    }

    private fun finishRecording() {
        if (state != State.RECORDING) return

        val wav = recorder.stop()
        recorder.onPcm = null
        val context = pendingContext
        pendingContext = null

        if (wav == null) {
            // A tap rather than a hold is not an error, but returning straight to the ordinary
            // idle label makes the gesture look ignored.
            liveSession?.cancel()
            liveSession = null
            showNotice("Recording was too short — try again")
            return
        }

        val key = Settings.apiKey
        if (key.isNullOrBlank()) {
            liveSession?.cancel()
            liveSession = null
            showFixInTheApp("No API key yet — tap here to add one")
            state = State.ERROR
            return
        }

        // Read at the moment the recording ends, not when the request returns: tapping a
        // different chip while a transcription is in flight must not change what it becomes.
        val style = Settings.liveStyle
        val live = liveSession
        liveSession = null

        state = State.TRANSCRIBING
        scope.launch {
            val outcome = withContext(Dispatchers.IO) {
                service.transcribe(wav, context, context?.appName, style, live)
            }
            outcome.fold(
                onSuccess = { record ->
                    // The rewrite when there is one, the transcript when there is not.
                    val delivered = record.styledText ?: record.text
                    // Where the user was looking when they spoke, not where they are looking now.
                    //
                    // commitText goes to whatever field holds focus at the moment it fires, which
                    // is the right answer only while that is still the same field. It stopped
                    // being the same field every time a dictation took a minute: the user gave up
                    // waiting and moved on, and the transcript arrived in whatever they had moved
                    // on to. On desktop, where this was found, that typed 292 characters of speech
                    // into the app's own settings window.
                    //
                    // Nothing is lost when this fires: the transcript is in the history and on the
                    // clipboard, one paste from where it was going.
                    val focusedNow = currentInputEditorInfo?.let { it.packageName to it.fieldId }
                    val movedOn = pendingTarget != null && focusedNow != pendingTarget
                    if (delivered.isNotEmpty() && movedOn) {
                        copyForManualPaste(delivered)
                        log.warn(
                            mapOf(
                                "spokeInto" to (pendingTarget?.first ?: "?"),
                                "nowFocused" to (focusedNow?.first ?: "none"),
                            ),
                        ) { "focus moved while transcribing; not typing into a field the user did not dictate into" }
                        showStatus("Copied — paste it where you want it")
                        state = State.ERROR
                        return@fold
                    }
                    if (delivered.isNotEmpty()) {
                        val insertionTarget = if (Settings.learnDictionaryFromEdits) {
                            captureEditableSnapshot()
                        } else {
                            null
                        }
                        currentInputConnection?.commitText(delivered, 1)
                        insertionTarget?.let { watchForCorrection(it, delivered) }
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
                    // Not a failure worth alarming anybody about: the microphone worked, the
                    // request was never made, and nothing was said. Reported plainly rather than
                    // as an error, and never as a transcript.
                    if (error is NoSpeechException) {
                        showNotice("No speech detected — recording wasn't sent")
                        return@fold
                    }
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
    private var undoLearningOnTap = false

    /// Says what is wrong and makes the label the way to fix it.
    private fun showFixInTheApp(message: String) {
        statusLabel.text = message
        openAppOnTap = true
        undoLearningOnTap = false
    }

    private fun captureEditableSnapshot(): EditableSnapshot? {
        val info = currentInputEditorInfo ?: return null
        if (isPasswordField(info.inputType)) return null
        val target = info.packageName to info.fieldId
        val connection = currentInputConnection ?: return null
        val extracted = connection.getExtractedText(ExtractedTextRequest(), 0) ?: return null
        val value = extracted.text?.toString() ?: return null
        // ExtractedText selection offsets are relative to `text`; startOffset locates that text
        // in the host's full document and must not be subtracted again.
        val start = extracted.selectionStart
        val end = extracted.selectionEnd
        if (start !in 0..value.length || end !in start..value.length) return null
        return EditableSnapshot(target, System.identityHashCode(connection), value, start, end)
    }

    /** Watches only the same active editor, briefly, for a stable spelling correction. */
    private fun watchForCorrection(before: EditableSnapshot, inserted: String) {
        correctionWatch?.cancel()
        val prefix = before.value.substring(0, before.selectionStart)
        val suffix = before.value.substring(before.selectionEnd)
        val target = before.target
        val connectionIdentity = before.connectionIdentity
        correctionWatch = scope.launch {
            var prior: String? = null
            var stableReads = 0
            repeat(80) { // 60 seconds at 750 ms.
                delay(750)
                val current = captureEditableSnapshot() ?: return@launch
                if (current.target != target
                    || current.connectionIdentity != connectionIdentity
                    || !current.value.startsWith(prefix)
                    || !current.value.endsWith(suffix)
                ) return@launch
                val end = current.value.length - suffix.length
                if (end < prefix.length) return@launch
                val edited = current.value.substring(prefix.length, end)
                if (edited == inserted) {
                    prior = null
                    stableReads = 0
                    return@repeat
                }
                if (edited == prior) stableReads++ else {
                    prior = edited
                    stableReads = 1
                }
                if (stableReads < 2) return@repeat
                val candidates = PersonalDictionary.learnedCandidates(inserted, edited)
                val added = Settings.learnDictionaryTerms(candidates)
                if (added.isNotEmpty()) {
                    lastLearnedTerms = added
                    openAppOnTap = false
                    undoLearningOnTap = true
                    statusLabel.text = "Learned ${added.joinToString()} — tap to undo"
                }
                return@launch
            }
        }
    }

    private fun undoLastLearning() {
        if (lastLearnedTerms.isEmpty()) return
        Settings.forgetLearnedDictionaryTerms(lastLearnedTerms)
        lastLearnedTerms = emptyList()
        undoLearningOnTap = false
        showStatus("Removed learned spelling")
    }

    private fun isPasswordField(inputType: Int): Boolean {
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        return when (inputType and InputType.TYPE_MASK_CLASS) {
            InputType.TYPE_CLASS_TEXT -> variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
            InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
    }

    /// Every other status goes through here, so the label stops being a button the moment it stops
    /// showing something the app can fix. A status line that silently opens an app is worse than
    /// one that does nothing.
    private fun showStatus(message: String) {
        statusLabel.text = message
        openAppOnTap = false
        undoLearningOnTap = false
    }

    /** Keeps a harmless outcome visible while leaving the talk button immediately reusable. */
    private fun showNotice(message: String) {
        noticeJob?.cancel()
        showStatus(message)
        state = State.NOTICE
        noticeJob = scope.launch {
            delay(3_000)
            if (state == State.NOTICE) state = State.IDLE
        }
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
        val hasAPIKey = !Settings.apiKey.isNullOrBlank()
        when (state) {
            State.IDLE -> {
                if (!hasAPIKey) {
                    showFixInTheApp("Add an API key in DoNotType before dictating")
                } else {
                    showStatus(if (ScreenReaderService.instance == null) {
                        "Tap to talk · screen grounding off"
                    } else {
                        "Tap to talk, or hold"
                    })
                }
                talkButton.text = if (hasAPIKey) "Tap to talk" else "API key required"
                talkButton.isEnabled = hasAPIKey
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
            State.NOTICE -> {
                // showNotice already supplied the meaningful line; do not overwrite it with the
                // generic idle prompt as the old IDLE transition did.
                talkButton.text = "Tap to talk"
                talkButton.isEnabled = hasAPIKey
                indicator.mode = DictationIndicatorView.Mode.IDLE
                stopLevelUpdates()
            }
            State.ERROR -> {
                talkButton.text = if (hasAPIKey) "Tap to talk" else "API key required"
                talkButton.isEnabled = hasAPIKey
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
         * It is [WavRecorder.MIN_DURATION_MS] exactly, and the two are the same number on purpose:
         * a release may only end a recording the recorder would accept. While this was the shorter
         * 350 ms it read as the more comfortable choice, but it opened a 150 ms window where a
         * press was long enough to be called a hold and too short to survive
         * [WavRecorder.MIN_DURATION_MS]. A press landing in it stopped the recording and then threw
         * it away, so the gesture that felt most like a tap was the one guaranteed to produce
         * nothing. Nobody says anything in under half a second, so every press that used to send
         * still sends; what changes is that a press between the two lengths now leaves the
         * recording running, with the button still showing it, instead of discarding it in silence.
         */
        const val HOLD_THRESHOLD_MS = WavRecorder.MIN_DURATION_MS
    }
}
