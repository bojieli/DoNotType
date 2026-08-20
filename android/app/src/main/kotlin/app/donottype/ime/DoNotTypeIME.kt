package app.donottype.ime

import app.donottype.PromptAssets
import app.donottype.R
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
import app.donottype.ui.themeColor
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.inputmethodservice.InputMethodService
import android.util.Log
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.ExtractedTextRequest
import android.view.inputmethod.EditorInfo
import android.text.InputType
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.content.res.AppCompatResources
import androidx.appcompat.view.ContextThemeWrapper
import androidx.core.graphics.ColorUtils
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
    private lateinit var returnButton: Button
    private lateinit var backspaceButton: ImageButton
    private lateinit var indicator: DictationIndicatorView

    /**
     * The context every view on the bar is built from, and every colour on it resolved against.
     *
     * An `InputMethodService` is a service, and a service's theme is whatever the platform picked
     * for input methods -- not Theme.DoNotType. Reading `?attr/colorPrimary` off `this` therefore
     * resolves against a theme that assigns none of the Material 3 roles the app's screens are
     * drawn from, and returns the platform's slate rather than the app's blue. That is why the
     * keyboard's palette used to be six hex literals, and why it stayed dark on a light phone.
     *
     * One wrapper fixes both: it carries the app's theme, and it delegates to the service's own
     * resources, so `values-night` answers for this bar exactly when it answers for the app.
     */
    private val ui: Context by lazy { ContextThemeWrapper(this, R.style.Theme_DoNotType) }

    private val state: State get() = dictation.state

    /** Which field was focused when the key went down: its app, and the editor's id within it. */
    private var pendingTarget: Pair<String?, Int>? = null
    private var correctionWatch: Job? = null
    private var backspaceRepeat: Job? = null
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
        // The field being typed into has just changed, and with it what its Enter key is for.
        refreshReturnKey()
        render()
        pendingLifecycleNotice?.let { message ->
            pendingLifecycleNotice = null
            showNotice(message)
        }
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        // Before anything else: a held backspace outlives the view it was pressed on, and would
        // keep deleting from whatever field the next keyboard opened on.
        stopBackspaceRepeat()
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
        val root = LinearLayout(ui).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(padSide, padTop, padSide, padBottom)
            setBackgroundColor(
                ui.themeColor(com.google.android.material.R.attr.colorSurfaceContainer),
            )
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            )

            // The keyboard window extends behind the navigation bar. A gesture pill is thin enough
            // to miss the button below it; a three-button bar is not, and covered the bottom half
            // of "Tap to talk" -- the only control this keyboard has.
            ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
                val nav = insets.getInsets(WindowInsetsCompat.Type.navigationBars())
                view.setPadding(padSide, padTop, padSide, padBottom + nav.bottom)
                insets
            }
        }

        statusLabel = TextView(ui).apply {
            textSize = 14f
            setTextColor(
                ui.themeColor(com.google.android.material.R.attr.colorOnSurfaceVariant),
            )
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
        indicator = DictationIndicatorView(ui)

        talkButton = buildTalkButton()
        returnButton = buildReturnButton()
        backspaceButton = buildBackspaceButton()

        root.addView(
            statusLabel,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(STATUS_DP)),
        )
        root.addView(
            indicator,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(METER_DP)),
        )

        root.addView(
            FrameLayout(ui).apply {
                addView(
                    talkButton,
                    FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, dp(TALK_H_DP), Gravity.CENTER,
                    ),
                )
            },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(TALK_H_DP)),
        )

        // The utility row, in iOS's order: mode on the left, return under the thumb in the middle,
        // backspace on the right where every other keyboard on the phone puts it. The mode chip
        // shares this row rather than overlapping the talk button, which is what it did while it
        // was the only thing beside it.
        root.addView(
            FrameLayout(ui).apply {
                addView(
                    modeButton,
                    FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT,
                        dp(MODE_H_DP),
                        Gravity.START or Gravity.CENTER_VERTICAL,
                    ),
                )
                addView(
                    returnButton,
                    FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, dp(KEY_H_DP), Gravity.CENTER,
                    ),
                )
                addView(
                    backspaceButton,
                    FrameLayout.LayoutParams(
                        dp(BACKSPACE_W_DP), dp(KEY_H_DP), Gravity.END or Gravity.CENTER_VERTICAL,
                    ),
                )
            },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(KEY_H_DP)).apply {
                topMargin = dp(ROW_GAP_DP)
            },
        )

        refreshModeButton()
        refreshReturnKey()
        render()
        return root
    }

    /**
     * The one control the keyboard is for: a capsule, matching the app's record button and iOS's
     * Speak button rather than the platform's rectangle.
     *
     * Its background is set per state by [renderTalkButton], so the shape is a drawable this file
     * owns rather than a `setBackgroundColor` -- which would replace the shape along with the
     * colour and leave a square button the first time the state changed.
     */
    private fun buildTalkButton(): Button = Button(ui).apply {
        textSize = 17f
        isAllCaps = false
        stateListAnimator = null
        // A minimum rather than a fixed width. The button is 170dp for "Tap to talk", which is
        // what iOS is, but its widest state is "API key required" -- and that clipped, so the one
        // state that explains why nothing works was the one state you could not read.
        minWidth = dp(TALK_W_DP)
        minimumWidth = dp(TALK_W_DP)
        minHeight = 0
        minimumHeight = 0
        gravity = Gravity.CENTER
        setPadding(dp(TALK_PAD_DP), 0, dp(TALK_PAD_DP), 0)
        compoundDrawablePadding = dp(6)
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

    /**
     * Shows the current live mode without taking horizontal space from the speaking control.
     *
     * Smaller than iOS's 86x34 pill, on purpose. iOS puts its mode control on a row of its own; on
     * this bar it sits beside the talk button, and at the old size a saturated block competed with
     * the one control the keyboard exists for. It is read far more often than it is pressed.
     */
    private fun buildModeButton(): Button = Button(ui).apply {
        textSize = 11f
        isAllCaps = false
        stateListAnimator = null
        minWidth = dp(MODE_W_DP)
        minimumWidth = dp(MODE_W_DP)
        minHeight = 0
        minimumHeight = 0
        setPadding(dp(9), 0, dp(9), 0)
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

    /**
     * Return, and the reason this keyboard needs one at all.
     *
     * A dictation keyboard replaces the system keyboard while it is up, so whatever it does not
     * offer, the user cannot do without switching keyboards first. Speaking a message and then
     * having to swap keyboards to send it is most of the cost of using this one, and the same goes
     * for fixing the last word. Two keys buy back both.
     *
     * Its width is a minimum, like the talk button's: "Previous" is half again as wide as "Go".
     */
    private fun buildReturnButton(): Button = Button(ui).apply {
        textSize = 14f
        isAllCaps = false
        stateListAnimator = null
        minWidth = dp(RETURN_W_DP)
        minimumWidth = dp(RETURN_W_DP)
        minHeight = 0
        minimumHeight = 0
        gravity = Gravity.CENTER
        compoundDrawablePadding = 0
        setOnClickListener { insertReturn() }
    }

    private fun buildBackspaceButton(): ImageButton = ImageButton(ui).apply {
        scaleType = ImageView.ScaleType.FIT_CENTER
        val inset = (dp(KEY_H_DP) - dp(BACKSPACE_ICON_DP)) / 2
        setPadding(inset, inset, inset, inset)
        contentDescription = "Delete"
        setImageDrawable(
            AppCompatResources.getDrawable(ui, R.drawable.ic_backspace)?.mutate()?.apply {
                setTint(ui.themeColor(com.google.android.material.R.attr.colorOnSurface))
            },
        )
        background = keyBackground(dp(KEY_CORNER_DP).toFloat())
        // Press and hold to run on, at iOS's timings: 0.38 s before the first repeat so a single
        // tap is never two deletions, then one every 65 ms, which clears a mis-heard word about as
        // fast as reading it.
        setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    startBackspaceRepeat()
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    stopBackspaceRepeat()
                    true
                }
                else -> false
            }
        }
        // Reached only by an accessibility activation: the touch handling above consumes real
        // presses without letting the framework detect a click, so a screen reader's tap is one
        // deletion rather than a press of some accidental length.
        setOnClickListener { if (backspaceRepeat == null) deleteBackward() }
    }

    // MARK: - Keys

    /**
     * What Return means here is the field's business, not the keyboard's.
     *
     * iOS's keyboard inserts a newline and stops there. On Android the field says what its Enter
     * key is for -- Search, Send, Go, Next, Done -- and a keyboard that ignores that turns every
     * search box into one that grows a blank line instead of searching. So the declared action wins
     * when there is one, and a newline is what is left when there is not.
     */
    private fun insertReturn() {
        val connection = currentInputConnection ?: return
        val action = declaredEditorAction()
        if (action != EditorInfo.IME_ACTION_NONE) {
            connection.performEditorAction(action)
        } else {
            connection.commitText("\n", 1)
        }
    }

    /** The field's own Enter action, or [EditorInfo.IME_ACTION_NONE] when it wants a newline. */
    private fun declaredEditorAction(): Int {
        val options = currentInputEditorInfo?.imeOptions ?: return EditorInfo.IME_ACTION_NONE
        if (options and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0) return EditorInfo.IME_ACTION_NONE
        return when (val action = options and EditorInfo.IME_MASK_ACTION) {
            EditorInfo.IME_ACTION_UNSPECIFIED, EditorInfo.IME_ACTION_NONE ->
                EditorInfo.IME_ACTION_NONE
            else -> action
        }
    }

    /** Names the key after what it will actually do, so it is readable before it is pressed. */
    private fun refreshReturnKey() {
        if (!::returnButton.isInitialized) return
        val label = when (declaredEditorAction()) {
            EditorInfo.IME_ACTION_GO -> "Go"
            EditorInfo.IME_ACTION_SEARCH -> "Search"
            EditorInfo.IME_ACTION_SEND -> "Send"
            EditorInfo.IME_ACTION_NEXT -> "Next"
            EditorInfo.IME_ACTION_PREVIOUS -> "Previous"
            EditorInfo.IME_ACTION_DONE -> "Done"
            else -> null
        }
        val onSurface = ui.themeColor(com.google.android.material.R.attr.colorOnSurface)
        val glyph = if (label == null) tinted(R.drawable.ic_return, onSurface, RETURN_ICON_DP) else null
        returnButton.text = label ?: ""
        returnButton.setTextColor(onSurface)
        // The glyph goes in the *top* slot rather than the start slot. A TextView draws a start
        // drawable hard against its left padding and then centres only the text in what is left,
        // which put the return arrow against the key's left edge; a top drawable it centres
        // horizontally for us. Vertical centring is then the padding's job, and with no text
        // beside the glyph that is simply half the key's spare height.
        returnButton.setCompoundDrawablesRelative(null, glyph, null, null)
        if (glyph == null) {
            returnButton.setPadding(dp(KEY_PAD_DP), 0, dp(KEY_PAD_DP), 0)
        } else {
            val inset = (dp(KEY_H_DP) - dp(RETURN_ICON_DP)) / 2
            returnButton.setPadding(0, inset, 0, inset)
        }
        returnButton.contentDescription = label ?: "Return"
        returnButton.background = keyBackground(dp(KEY_CORNER_DP).toFloat())
    }

    /**
     * One deletion, as a key event rather than `deleteSurroundingText`.
     *
     * The editor on the other side is the only thing that knows whether the character before the
     * cursor is one `char` or two, or whether there is a selection to remove instead -- and it
     * already handles DEL correctly for both. Counting characters here would eat half an emoji.
     */
    private fun deleteBackward() {
        val connection = currentInputConnection ?: return
        connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL))
        connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DEL))
    }

    private fun startBackspaceRepeat() {
        stopBackspaceRepeat()
        deleteBackward()
        backspaceRepeat = scope.launch {
            delay(BACKSPACE_FIRST_REPEAT_MS)
            while (true) {
                deleteBackward()
                delay(BACKSPACE_REPEAT_MS)
            }
        }
    }

    private fun stopBackspaceRepeat() {
        backspaceRepeat?.cancel()
        backspaceRepeat = null
    }

    // MARK: - Bar styling

    /**
     * The flat keys' background: a rounded fill that lightens under a finger.
     *
     * A [RippleDrawable] rather than a state list of colours, because a key with no press feedback
     * reads as unresponsive on a surface where nothing else moves -- and on a keyboard the press is
     * the only confirmation there is until the text appears.
     */
    private fun keyBackground(radius: Float): Drawable {
        val fill = GradientDrawable().apply {
            cornerRadius = radius
            setColor(
                ui.themeColor(com.google.android.material.R.attr.colorSurfaceContainerHighest),
            )
        }
        return RippleDrawable(ColorStateList.valueOf(rippleColor()), fill, null)
    }

    /** A filled capsule or key in [color], pressable. Used for the talk button and the mode chip. */
    private fun filled(color: Int, radius: Float): Drawable {
        val fill = GradientDrawable().apply {
            cornerRadius = radius
            setColor(color)
        }
        return RippleDrawable(ColorStateList.valueOf(rippleColor()), fill, null)
    }

    /** Visible against both a light and a dark fill without becoming a second colour. */
    private fun rippleColor(): Int = ColorUtils.setAlphaComponent(
        ui.themeColor(com.google.android.material.R.attr.colorOnSurface),
        RIPPLE_ALPHA,
    )

    private fun tinted(id: Int, color: Int, sizeDp: Int): Drawable? =
        AppCompatResources.getDrawable(ui, id)?.mutate()?.apply {
            setTint(color)
            setBounds(0, 0, dp(sizeDp), dp(sizeDp))
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
        // Rewrite is the container pair rather than a second saturated fill: two equally loud
        // chips beside the talk button would compete with it, and the mode is a label more often
        // than it is a control.
        modeButton.setTextColor(
            ui.themeColor(
                if (rewrite) {
                    com.google.android.material.R.attr.colorOnTertiaryContainer
                } else {
                    com.google.android.material.R.attr.colorOnPrimary
                },
            ),
        )
        modeButton.background = filled(
            ui.themeColor(
                if (rewrite) {
                    com.google.android.material.R.attr.colorTertiaryContainer
                } else {
                    androidx.appcompat.R.attr.colorPrimary
                },
            ),
            dp(MODE_H_DP) / 2f,
        )
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
                renderTalkButton(
                    text = if (hasAPIKey) "Tap to talk" else "API key required",
                    icon = R.drawable.ic_mic,
                    enabled = hasAPIKey,
                )
                indicator.mode = DictationIndicatorView.Mode.IDLE
            }
            State.RECORDING -> {
                showStatus("Listening…")
                renderTalkButton(text = "Tap to stop", icon = R.drawable.ic_stop, recording = true)
                indicator.mode = DictationIndicatorView.Mode.RECORDING
            }
            State.TRANSCRIBING -> {
                // Named rather than left as a spinner: after you stop talking the wait is dead
                // time, and "Transcribing" tells you what is consuming it and that it will end.
                showStatus("Transcribing…")
                renderTalkButton(text = "Working…", icon = null, enabled = false)
                indicator.mode = DictationIndicatorView.Mode.TRANSCRIBING
            }
            State.NOTICE -> {
                // showNotice already supplied the meaningful line; do not overwrite it with the
                // generic idle prompt as the old IDLE transition did.
                renderTalkButton(
                    text = "Tap to talk",
                    icon = R.drawable.ic_mic,
                    enabled = hasAPIKey,
                )
                indicator.mode = DictationIndicatorView.Mode.IDLE
            }
            State.ERROR -> {
                renderTalkButton(
                    text = if (hasAPIKey) "Tap to talk" else "API key required",
                    icon = R.drawable.ic_mic,
                    enabled = hasAPIKey,
                )
                indicator.mode = DictationIndicatorView.Mode.IDLE
            }
        }
        refreshModeButton()
    }

    /**
     * The talk button, in one place so its shape cannot be lost with its colour.
     *
     * Red while recording, for the same reason the app's record button is: it is the one state
     * where the next press throws something away if it was not meant, and the colour is the only
     * part of the button visible from across a room.
     */
    private fun renderTalkButton(
        text: String,
        icon: Int?,
        enabled: Boolean = true,
        recording: Boolean = false,
    ) {
        val fill = ui.themeColor(
            when {
                recording -> androidx.appcompat.R.attr.colorError
                enabled -> androidx.appcompat.R.attr.colorPrimary
                else -> com.google.android.material.R.attr.colorSurfaceContainerHighest
            },
        )
        val onFill = ui.themeColor(
            when {
                recording -> com.google.android.material.R.attr.colorOnError
                enabled -> com.google.android.material.R.attr.colorOnPrimary
                else -> com.google.android.material.R.attr.colorOnSurfaceVariant
            },
        )
        talkButton.text = text
        talkButton.isEnabled = enabled
        talkButton.setTextColor(onFill)
        // setCompoundDrawablesRelative rather than ...WithIntrinsicBounds, which re-derives the
        // bounds from the vector's own 24dp and throws away the size asked for here.
        talkButton.setCompoundDrawablesRelative(
            icon?.let { tinted(it, onFill, TALK_ICON_DP) }, null, null, null,
        )
        // Half the height, so both ends are semicircles: the capsule iOS gets from
        // `cornerStyle = .capsule`, and the same shape as the app's own record control.
        talkButton.background = filled(fill, dp(TALK_H_DP) / 2f)
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density + 0.5f).toInt()

    // The bar's own padding, in dp. It was three raw pixel constants -- 48, 32, 32 -- which is
    // 18dp of gutter on a 2.6x phone and less on a denser one, the same mistake the app's screens
    // were built on before res/values/dimens.xml.
    private val padSide: Int get() = dp(PAD_SIDE_DP)
    private val padTop: Int get() = dp(PAD_TOP_DP)
    private val padBottom: Int get() = dp(PAD_BOTTOM_DP)

    /**
     * The bar's geometry, in dp, matching the iOS keyboard's so the two feel like one product.
     *
     * iOS is 170x58 for the Speak button with a 29pt radius, and points and dp are the same size in
     * the hand, so that number carries over unchanged; only the total height differs, because iOS
     * pins its keyboard to 170pt and an Android IME is as tall as its content. The mode chip is
     * deliberately smaller than iOS's 86x34 -- see [buildModeButton].
     *
     * The widths are minimums, not fixed sizes. iOS lays its keys out in English and never has to
     * fit anything longer, whereas these labels change with what has gone wrong ("API key
     * required") -- and a control that clips its own label is worse than one a few dp wider than
     * its counterpart.
     */
    private companion object {
        const val TAG = "DoNotTypeIME"

        const val PAD_SIDE_DP = 12
        const val PAD_TOP_DP = 6
        const val PAD_BOTTOM_DP = 8

        const val STATUS_DP = 34
        const val METER_DP = 26

        const val TALK_W_DP = 170
        const val TALK_H_DP = 58
        const val TALK_ICON_DP = 22
        const val TALK_PAD_DP = 20

        const val MODE_W_DP = 68
        const val MODE_H_DP = 28

        /** The flat keys, at iOS's 38dp height and 10pt corner. */
        const val ROW_GAP_DP = 6
        const val KEY_H_DP = 38
        const val KEY_CORNER_DP = 10
        const val KEY_PAD_DP = 10
        const val RETURN_W_DP = 84
        const val RETURN_ICON_DP = 20
        const val BACKSPACE_W_DP = 52
        const val BACKSPACE_ICON_DP = 22

        /** iOS's key-repeat timings, so a held backspace runs on at the same speed on both. */
        const val BACKSPACE_FIRST_REPEAT_MS = 380L
        const val BACKSPACE_REPEAT_MS = 65L

        /** Visible against both a light and a dark fill without becoming a second fill. */
        const val RIPPLE_ALPHA = 40
    }
}
