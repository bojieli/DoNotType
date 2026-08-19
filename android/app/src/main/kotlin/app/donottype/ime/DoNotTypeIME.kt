package app.donottype.ime

import app.donottype.PromptAssets
import app.donottype.Settings
import app.donottype.accessibility.ScreenReaderService
import app.donottype.SettingsActivity
import app.donottype.core.DictationController
import app.donottype.core.DictationController.State
import app.donottype.core.DictationRecord
import app.donottype.core.DictationService
import app.donottype.core.FailureAdvice
import app.donottype.core.NoSpeechException
import app.donottype.core.Log as DntLog
import app.donottype.core.RewriteAvailability
import app.donottype.core.PersonalDictionary
import android.content.Intent
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
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
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


    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val service by lazy { DictationService(this) }

    /**
     * The dictation itself, shared with the app's own dictation screen rather than written twice.
     * What is left in this file is the half a keyboard cannot share: which field the words are for,
     * typing them into it, and watching what the user does to them afterwards.
     */
    private val dictation by lazy { DictationController(this, scope, service) }

    private lateinit var statusLabel: TextView
    private lateinit var modeButton: Button
    private lateinit var talkButton: Button
    private lateinit var indicator: DictationIndicatorView

    private val state: State get() = dictation.state

    /** Which field was focused when the key went down: its app, and the editor's id within it. */
    private var pendingTarget: Pair<String?, Int>? = null
    private var correctionWatch: Job? = null
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
        wireDictation()
    }

    override fun onDestroy() {
        scope.cancel()
        correctionWatch?.cancel()
        dictation.dispose()
        super.onDestroy()
    }

    /**
     * What the keyboard contributes to a dictation: the screen behind the field, the words for a
     * refusal, and somewhere to put the transcript.
     */
    private fun wireDictation() {
        dictation.onState = { state ->
            if (state == State.RECORDING) {
                // The last moment the focused field is still the one being dictated into. The
                // recorder opens synchronously with the press, so this is the press.
                pendingTarget = currentInputEditorInfo?.let { it.packageName to it.fieldId }
            }
            render()
        }
        dictation.onLevels = { bars -> indicator.appendLevels(bars) }
        dictation.logContext = {
            mapOf("package" to (currentInputEditorInfo?.packageName ?: "?"))
        }
        // Phase 1 equivalent of the screen capture: read at press, while the field being dictated
        // into is still the focused one. Never for a password field, whatever grounding says.
        dictation.screenContext = {
            val passwordField =
                currentInputEditorInfo?.let { isPasswordField(it.inputType) } == true
            if (Settings.groundingEnabled && !passwordField) {
                ScreenReaderService.instance?.capture()
            } else {
                null
            }
        }
        // A keyboard cannot grant itself a permission or hold an API key, so both refusals point
        // at the app, and the label becomes the way to get there.
        dictation.onRefused = { reason, error ->
            when (reason) {
                DictationController.Refusal.NO_API_KEY ->
                    showFixInTheApp("No API key yet — tap here to add one")
                DictationController.Refusal.NO_MICROPHONE ->
                    showFixInTheApp("Microphone access is off — tap here to grant it")
                // A tap rather than a hold is not an error, but returning straight to the ordinary
                // idle label makes the gesture look ignored.
                DictationController.Refusal.TOO_SHORT ->
                    showStatus("Recording was too short — try again")
                DictationController.Refusal.COULD_NOT_START ->
                    showStatus(error?.message ?: "Could not start recording")
            }
        }
        dictation.onResult = { outcome -> deliver(outcome) }
    }

    override fun onStartInputView(info: android.view.inputmethod.EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        correctionWatch?.cancel()
        // Anything that failed while offline goes out when the keyboard next opens.
        scope.launch { withContext(Dispatchers.IO) { service.retryAll() } }
        // The provider may have changed in the app since this keyboard was last shown, and with it
        // whether a rewrite is possible at all.
        refreshModeButton()
        render()
        pendingLifecycleNotice?.let { message ->
            pendingLifecycleNotice = null
            showNotice(message)
        }
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        dictation.cancelPress()

        if (state == State.RECORDING) {
            log.info { "recording stopped because the keyboard closed" }
            discardRecording()
            // The view is going away, so retain the explanation and show it when the keyboard next
            // opens instead of starting a three-second notice that expires while nobody can see it.
            pendingLifecycleNotice = "Recording stopped when the keyboard closed"
            dictation.idle()
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
            setPadding(0, 0, 0, 0)
            maxLines = 2
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

        modeButton = buildModeButton()
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
                        dictation.pressDown(event.eventTime)
                        true
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        dictation.pressUp(
                            cancelled = event.action == MotionEvent.ACTION_CANCEL,
                            eventTime = event.eventTime,
                        )
                        true
                    }
                    else -> false
                }
            }
        }

        root.addView(
            statusLabel,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(36)),
        )
        root.addView(
            indicator,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(28)),
        )

        val primaryRow = FrameLayout(this).apply {
            addView(
                talkButton,
                FrameLayout.LayoutParams(dp(160), dp(56), Gravity.CENTER),
            )
            addView(
                modeButton,
                FrameLayout.LayoutParams(dp(80), dp(34), Gravity.START or Gravity.CENTER_VERTICAL),
            )
        }
        root.addView(
            primaryRow,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56)),
        )
        refreshModeButton()
        render()
        return root
    }

    /** Shows the current live mode without taking horizontal space from the speaking control. */
    private fun buildModeButton(): Button = Button(this).apply {
        textSize = 12f
        isAllCaps = false
        minWidth = 0
        minimumWidth = 0
        minHeight = 0
        minimumHeight = 0
        setPadding(dp(8), dp(2), dp(8), dp(2))
        setOnClickListener {
            val rewrite = !Settings.rewriteModeEnabled
            val availability = RewriteAvailability.resolve(Settings.provider) {
                !Settings.keyFor(it).isNullOrBlank()
            }
            if (rewrite && !availability.isAvailable) {
                availability.reason?.let { statusLabel.text = it }
                log.info { "rewrite mode unavailable" }
                return@setOnClickListener
            }
            Settings.rewriteModeEnabled = rewrite
            log.info(mapOf("mode" to if (rewrite) "rewrite" else "dictate")) {
                "live mode chosen"
            }
            refreshModeButton()
        }
    }

    private fun refreshModeButton() {
        if (!::modeButton.isInitialized) return
        val availability = RewriteAvailability.resolve(Settings.provider) {
            !Settings.keyFor(it).isNullOrBlank()
        }
        if (!availability.isAvailable && Settings.rewriteModeEnabled) {
            Settings.rewriteModeEnabled = false
        }
        // finishRecording reads the style after capture stops, so the current recording may be
        // corrected from Dictate to Rewrite (or back) without interrupting the speaker.
        val canChange = state != State.TRANSCRIBING
        val rewrite = Settings.rewriteModeEnabled
        val canSwitch = canChange && (rewrite || availability.isAvailable)
        val current = if (rewrite) "Rewrite" else "Dictate"
        val next = if (rewrite) "Dictate" else "Rewrite"
        modeButton.text = current
        modeButton.isEnabled = canSwitch
        modeButton.alpha = if (canSwitch) 1f else 0.55f
        modeButton.setTextColor(Color.parseColor("#0B0F14"))
        modeButton.setBackgroundColor(Color.parseColor(if (rewrite) "#B69CFF" else "#7FB2FF"))
        modeButton.contentDescription = when {
            canSwitch -> "Current mode: $current. Tap to switch to $next"
            !canChange -> "Current mode: $current. Mode is fixed while transcribing"
            else -> "Current mode: $current. Rewrite is unavailable"
        }
    }

    // MARK: - Dictation

    /** Discards capture, and the keyboard's note of where its words were going. */
    private fun discardRecording() {
        dictation.discard()
        pendingTarget = null
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

    /**
     * Where a finished dictation goes.
     *
     * Everything up to here is shared with the app's dictation screen; this is not. A keyboard has
     * a field it was aimed at, and typing into the wrong one is worse than not typing at all.
     */
    private fun deliver(outcome: Result<DictationRecord>) {
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
                    dictation.failed()
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
                    dictation.failed()
                } else {
                    dictation.idle()
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
                dictation.failed()
            },
        )
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
        showStatus(message)
        dictation.notice()
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
            }
            State.RECORDING -> {
                showStatus("Listening…")
                talkButton.text = "Tap to stop"
                talkButton.isEnabled = true
                indicator.mode = DictationIndicatorView.Mode.RECORDING
            }
            State.TRANSCRIBING -> {
                // Named rather than left as a spinner: after you stop talking the wait is dead
                // time, and "Transcribing" tells you what is consuming it and that it will end.
                showStatus("Transcribing…")
                talkButton.text = "Working…"
                talkButton.isEnabled = false
                indicator.mode = DictationIndicatorView.Mode.TRANSCRIBING
            }
            State.NOTICE -> {
                // showNotice already supplied the meaningful line; do not overwrite it with the
                // generic idle prompt as the old IDLE transition did.
                talkButton.text = "Tap to talk"
                talkButton.isEnabled = hasAPIKey
                indicator.mode = DictationIndicatorView.Mode.IDLE
            }
            State.ERROR -> {
                talkButton.text = if (hasAPIKey) "Tap to talk" else "API key required"
                talkButton.isEnabled = hasAPIKey
                indicator.mode = DictationIndicatorView.Mode.IDLE
            }
        }
        refreshModeButton()
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density + 0.5f).toInt()

    private companion object {
        const val TAG = "DoNotTypeIME"

        const val PAD_SIDE = 48
        const val PAD_TOP = 32
        const val PAD_BOTTOM = 32
    }
}
