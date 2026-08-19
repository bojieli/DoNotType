package app.donottype

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.lifecycleScope
import app.donottype.core.DictationController
import app.donottype.core.DictationRecord
import app.donottype.core.DictationService
import app.donottype.core.FailureAdvice
import app.donottype.core.Log
import app.donottype.core.NoSpeechException
import app.donottype.core.RewriteAvailability
import app.donottype.ui.LevelMeterView
import app.donottype.ui.RecordButtonView
import app.donottype.ui.caption
import app.donottype.ui.cardHolding
import app.donottype.ui.columnParams
import app.donottype.ui.dp
import app.donottype.ui.textButton
import app.donottype.ui.themeColor
import app.donottype.ui.tonalButton
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.button.MaterialButton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * What the app opens on: a button you press to talk.
 *
 * Until now the launcher opened Settings, so the first thing anybody saw of this app was its
 * configuration. That is backwards for a dictation app on a phone, and it is not what the iOS build
 * does — there the settings are one gear away and the screen you land on is this one. It matters
 * beyond first impressions: the keyboard is not the only place somebody wants to dictate from, and
 * without a screen of its own the app could only record while a text field somewhere else had
 * focus.
 *
 * There is no field to type into here, so a finished dictation goes to the clipboard and to
 * history. That is the honest Android reading of what iOS calls "waiting in the keyboard": the
 * words exist, they are one paste from wherever they were meant to go, and nothing was typed into
 * a field the user did not choose.
 *
 * Every part of the dictation itself — the preflight, the gesture timing, the levels, the request —
 * is [DictationController], the same instance type the keyboard drives. What this screen adds is
 * the two things a keyboard cannot do: ask for the microphone permission, and show more than one
 * line about what went wrong.
 */
class DictationActivity : AppCompatActivity() {

    private lateinit var modeDictate: TextView
    private lateinit var modeRewrite: TextView
    private lateinit var recordButton: RecordButtonView
    private lateinit var meter: LevelMeterView
    private lateinit var statusLabel: TextView
    private lateinit var cancelButton: MaterialButton
    private lateinit var settingsLink: MaterialButton
    private lateinit var latestSection: View
    private lateinit var latestText: TextView
    private lateinit var pendingButton: MaterialButton

    private val log = Log("screen")
    private val service by lazy { DictationService(this) }
    private val dictation by lazy { DictationController(this, lifecycleScope, service) }

    /**
     * What the status line says instead of its ordinary idle sentence.
     *
     * Kept by the screen rather than by the controller because it outlives a state: a recording
     * stopped by the app going to the background has to still explain itself when the user comes
     * back, however long that takes, and a three-second notice would have expired while nobody
     * could see it.
     */
    private var message: String? = null
    private var messageIsError = false

    /** Set while the microphone dialog is up, so its answer can start the dictation that asked. */
    private var recordAfterPermission = false

    private val microphone = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            say(null)
            // The press that was refused becomes the press that records: making somebody grant a
            // permission and then press the button again is one step more than the moment needs.
            if (recordAfterPermission) dictation.begin()
        } else {
            // Not "denied" — what to do about it. A second refusal means Android will not ask
            // again, and the only remaining route is the app's own settings page.
            say(
                "Microphone access is off. Turn it on in Android's app settings to dictate.",
                isError = true,
            )
        }
        recordAfterPermission = false
        render()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Settings.initialise(this)
        title = getString(R.string.app_name)
        setContentView(buildLayout())
        wireDictation()
        render()
    }

    override fun onResume() {
        super.onResume()
        // The provider may have changed in Settings since this screen was last shown, and with it
        // whether a rewrite is possible at all.
        refreshMode()
        refreshHistory()
        // Anything that failed while offline goes out as soon as the app is foregrounded.
        lifecycleScope.launch {
            withContext(Dispatchers.IO) { service.retryAll() }
            refreshHistory()
        }
        render()
    }

    override fun onStop() {
        dictation.cancelPress()
        if (dictation.state == DictationController.State.RECORDING) {
            log.info { "recording stopped because the app left the foreground" }
            dictation.discard()
            // Deliberately not a three-second notice. The process may be suspended for an hour;
            // this should still explain the stopped recording whenever the user returns.
            say("Recording stopped when DoNotType left the foreground")
            dictation.idle()
        }
        super.onStop()
    }

    override fun onDestroy() {
        dictation.dispose()
        super.onDestroy()
    }

    // MARK: - Layout

    private fun buildLayout(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(
                themeColor(com.google.android.material.R.attr.colorSurface),
            )
        }
        root.addView(buildToolbar())

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            val gutter = resources.getDimensionPixelSize(R.dimen.screen_gutter)
            setPadding(gutter, 0, gutter, resources.getDimensionPixelSize(R.dimen.space_l))
        }

        column.addView(spacer())
        column.addView(buildModeBadge())

        recordButton = RecordButtonView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                topMargin = resources.getDimensionPixelSize(R.dimen.space_l)
            }
        }
        column.addView(recordButton)

        // Reserved rather than inserted: a meter that appeared on the first word would push the
        // button out from under the thumb that is holding it.
        meter = LevelMeterView(this).apply {
            alpha = 0f
            layoutParams = LinearLayout.LayoutParams(dp(220), dp(36)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                topMargin = resources.getDimensionPixelSize(R.dimen.space_l)
            }
        }
        column.addView(meter)

        // Never given a line limit. Failures arrive here in FailureAdvice's own words, written to
        // be acted on and to be copied into a bug report intact.
        statusLabel = TextView(this).apply {
            gravity = Gravity.CENTER
            setTextIsSelectable(true)
            layoutParams = columnParams(top = resources.getDimensionPixelSize(R.dimen.space_l))
        }
        column.addView(statusLabel)

        cancelButton = tonalButton("Cancel transcription") {
            dictation.cancelTranscription()
            say("Cancelled")
            dictation.notice()
        }.apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                topMargin = resources.getDimensionPixelSize(R.dimen.space_s)
            }
            contentDescription = "cancel-transcription"
        }
        column.addView(cancelButton)

        settingsLink = textButton("Add an API key in Settings") { openSettings() }.apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { gravity = Gravity.CENTER_HORIZONTAL }
            contentDescription = "configure-api-key"
        }
        column.addView(settingsLink)

        column.addView(spacer())
        column.addView(buildLatest())
        column.addView(buildPendingBanner())

        val scroll = ScrollView(this).apply {
            isFillViewport = true
            addView(
                column,
                ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f,
            )
        }
        root.addView(scroll)

        // Android 15 draws every app edge to edge whether it asked to or not. Padded on the root
        // rather than on the scroll view, because the toolbar above it has to clear the status bar
        // too, and this screen's content is centred rather than scrolled past the bars.
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        return root
    }

    /**
     * The three places this screen leads: what has been dictated, a recording that already exists,
     * and everything else. The same three iOS puts in its toolbar, expressed as an Android action
     * bar rather than as leading and trailing items.
     */
    private fun buildToolbar(): MaterialToolbar = MaterialToolbar(this).apply {
        title = getString(R.string.app_name)
        setTitleTextColor(themeColor(com.google.android.material.R.attr.colorOnSurface))
        addAction(MENU_HISTORY, "History", R.drawable.ic_history)
        addAction(MENU_FILES, "Transcribe a recording", R.drawable.ic_waveform)
        addAction(MENU_SETTINGS, "Settings", R.drawable.ic_settings)
        setOnMenuItemClickListener { item ->
            when (item.itemId) {
                MENU_HISTORY -> open(HistoryActivity::class.java)
                MENU_FILES -> open(FileTranscriptionActivity::class.java)
                MENU_SETTINGS -> openSettings()
                else -> return@setOnMenuItemClickListener false
            }
            true
        }
    }

    private fun MaterialToolbar.addAction(id: Int, title: String, icon: Int) {
        menu.add(Menu.NONE, id, Menu.NONE, title).apply {
            setIcon(icon)
            setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
        }
    }

    /**
     * The phone equivalent of the desktop's two hotkeys: which operation the next press performs.
     * Which *style* it rewrites in is a setting, deliberately kept out of here — mixing it with the
     * choice of operation is what made this control unreadable on the keyboard bar.
     */
    private fun buildModeBadge(): View {
        modeDictate = modeSegment("Dictate") { choose(rewrite = false) }
        modeRewrite = modeSegment("Rewrite") { choose(rewrite = true) }
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            val inset = dp(3)
            setPadding(inset, inset, inset, inset)
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(22).toFloat()
                setColor(
                    themeColor(com.google.android.material.R.attr.colorSurfaceContainerHighest),
                )
            }
            addView(modeDictate)
            addView(modeRewrite)
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { gravity = Gravity.CENTER_HORIZONTAL }
        }
    }

    private fun modeSegment(title: String, onClick: () -> Unit): TextView = TextView(this).apply {
        text = title
        gravity = Gravity.CENTER
        setPadding(dp(18), dp(8), dp(18), dp(8))
        isClickable = true
        isFocusable = true
        setOnClickListener { onClick() }
    }

    /**
     * The last thing this app produced, so the screen has something to show for itself and the
     * words are visible without a trip to history.
     *
     * Clamped, unlike a failure: this is a preview of something that succeeded, the whole of it is
     * one tap away in History, and four lines is what iOS shows in the same place.
     */
    private fun buildLatest(): View {
        latestText = TextView(this).apply {
            maxLines = 4
            ellipsize = android.text.TextUtils.TruncateAt.END
            setTextColor(themeColor(com.google.android.material.R.attr.colorOnSurface))
        }
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val padding = resources.getDimensionPixelSize(R.dimen.space_m)
            setPadding(padding, padding, padding, padding)
            addView(caption("Latest").apply { layoutParams = columnParams() })
            addView(
                latestText,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply { topMargin = resources.getDimensionPixelSize(R.dimen.space_xs) },
            )
            addView(caption("Copied to the clipboard. Tap to see all of it."))
        }
        latestSection = cardHolding(body).apply {
            visibility = View.GONE
            isClickable = true
            setOnClickListener { open(HistoryActivity::class.java) }
            contentDescription = "latest-transcript"
        }
        return latestSection
    }

    private fun buildPendingBanner(): View {
        pendingButton = tonalButton("") {
            lifecycleScope.launch {
                pendingButton.isEnabled = false
                val (succeeded, failed) = service.retryAll()
                say("$succeeded succeeded, $failed still failing")
                dictation.notice()
                refreshHistory()
                render()
            }
        }.apply {
            icon = ContextCompat.getDrawable(this@DictationActivity, R.drawable.ic_retry)
            visibility = View.GONE
            contentDescription = "retry-pending"
        }
        return pendingButton
    }

    private fun spacer(): View = View(this).apply {
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            0,
            1f,
        )
    }

    // MARK: - Dictation

    /**
     * What this screen contributes to a dictation: the words for a refusal, and somewhere to put
     * the transcript. Everything between the press and the result is the shared controller's.
     */
    private fun wireDictation() {
        dictation.onState = { render() }
        dictation.onLevels = { bars ->
            meter.appendLevels(bars)
            recordButton.level = meter.newestLevel
        }
        dictation.logContext = { mapOf("surface" to "app") }
        // Grounding reads the screen behind a text field, and there is no text field here — the
        // app screen is the one place in this app where the screen context is always the app's own.
        dictation.screenContext = { null }
        dictation.onRefused = { reason, error ->
            when (reason) {
                // Unlike the keyboard, this screen can fix both of the first two in place rather
                // than pointing somewhere else: the permission dialog is one call away, and
                // Settings is one tap.
                DictationController.Refusal.NO_API_KEY ->
                    say("Add an API key in Settings before dictating.", isError = true)
                DictationController.Refusal.NO_MICROPHONE -> {
                    say("Microphone access is off.")
                    recordAfterPermission = true
                    microphone.launch(Manifest.permission.RECORD_AUDIO)
                }
                // A tap rather than a hold is not an error, but returning straight to the ordinary
                // idle label makes the gesture look ignored.
                DictationController.Refusal.TOO_SHORT ->
                    say("Recording was too short — try again")
                DictationController.Refusal.COULD_NOT_START ->
                    say(error?.message ?: "Could not start recording", isError = true)
            }
        }
        dictation.onResult = { outcome -> deliver(outcome) }

        recordButton.onPressDown = { time ->
            say(null)
            dictation.pressDown(time)
        }
        recordButton.onPressUp = { cancelled, time -> dictation.pressUp(cancelled, time) }
        recordButton.onActivate = {
            // One event rather than a press and a release, so it is an unambiguous start or stop.
            if (dictation.state == DictationController.State.RECORDING) {
                dictation.finish()
            } else {
                say(null)
                dictation.begin()
            }
        }
    }

    /**
     * Where a finished dictation goes when there is no field to put it in.
     *
     * The clipboard, and history. The words have been recorded, sent and paid for by the time this
     * runs, and the difference between "paste it" and "nothing happened" is the difference between
     * one gesture and an app that looks broken.
     */
    private fun deliver(outcome: Result<DictationRecord>) {
        outcome.fold(
            onSuccess = { record ->
                val delivered = record.deliveredText
                if (delivered.isNotEmpty()) copyToClipboard(delivered)
                refreshHistory()
                if (record.rewriteFailed) {
                    // The words landed either way, but somebody who chose Rewrite and got their
                    // own words back should be told that is what happened.
                    say("Copied — not rewritten")
                    dictation.notice()
                } else {
                    say(null)
                    dictation.idle()
                }
            },
            onFailure = { error ->
                // Not a failure worth alarming anybody about: the microphone worked, the request
                // was never made, and nothing was said.
                if (error is NoSpeechException) {
                    say("No speech detected — recording wasn't sent")
                    dictation.notice()
                    return@fold
                }
                log.error(mapOf("detail" to FailureAdvice.detail(error))) { "dictation failed" }
                // What happened and what to do about it, in full. This screen has room for the
                // whole sentence, which is the one advantage it has over the keyboard bar.
                say(FailureAdvice.describe(error).message, isError = true)
                dictation.failed()
                refreshHistory()
            },
        )
    }

    private fun copyToClipboard(text: String) {
        runCatching {
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText("DoNotType transcript", text))
        }
    }

    // MARK: - Mode

    private fun choose(rewrite: Boolean) {
        if (dictation.state == DictationController.State.TRANSCRIBING) return
        val availability = RewriteAvailability.resolve(Settings.provider) {
            !Settings.keyFor(it).isNullOrBlank()
        }
        if (rewrite && !availability.isAvailable) {
            // Ordinarily unreachable: refreshMode() disables the segment, which is what iOS's badge
            // does too, and Settings is where the reason is spelled out on both. This is the guard
            // for a key that disappeared since the last refresh -- saying why beats a segment that
            // silently refuses. The sentence is word-identical across the four clients; see
            // docs/PARITY.md.
            availability.reason?.let { say(it, isError = true) }
            return
        }
        Settings.rewriteModeEnabled = rewrite
        log.info(mapOf("mode" to if (rewrite) "rewrite" else "dictate")) { "live mode chosen" }
        refreshMode()
    }

    private fun refreshMode() {
        val availability = RewriteAvailability.resolve(Settings.provider) {
            !Settings.keyFor(it).isNullOrBlank()
        }
        if (!availability.isAvailable && Settings.rewriteModeEnabled) {
            Settings.rewriteModeEnabled = false
        }
        val rewrite = Settings.rewriteModeEnabled
        paintSegment(modeDictate, selected = !rewrite)
        paintSegment(modeRewrite, selected = rewrite)
        // finish() reads the style after capture stops, so a recording in progress may be corrected
        // from Dictate to Rewrite without interrupting the speaker; a request already out may not.
        val canChange = dictation.state != DictationController.State.TRANSCRIBING
        modeDictate.isEnabled = canChange
        modeRewrite.isEnabled = canChange && (rewrite || availability.isAvailable)
        modeRewrite.alpha = if (modeRewrite.isEnabled) 1f else 0.55f
        modeDictate.contentDescription = "mode-dictate"
        modeRewrite.contentDescription = "mode-rewrite"
    }

    private fun paintSegment(segment: TextView, selected: Boolean) {
        segment.background = if (selected) {
            GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(19).toFloat()
                setColor(themeColor(androidx.appcompat.R.attr.colorPrimary))
            }
        } else {
            null
        }
        segment.setTextColor(
            themeColor(
                if (selected) {
                    com.google.android.material.R.attr.colorOnPrimary
                } else {
                    com.google.android.material.R.attr.colorOnSurface
                },
            ),
        )
        segment.isSelected = selected
    }

    // MARK: - Rendering

    /** The one place the status line is written, so its colour never lags behind its text. */
    private fun say(text: String?, isError: Boolean = false) {
        message = text
        messageIsError = isError
        render()
    }

    private fun render() {
        if (!::statusLabel.isInitialized) return
        val state = dictation.state
        val hasAPIKey = !Settings.apiKey.isNullOrBlank()

        recordButton.look = when (state) {
            DictationController.State.RECORDING -> RecordButtonView.Look.RECORDING
            DictationController.State.TRANSCRIBING -> RecordButtonView.Look.WORKING
            else -> RecordButtonView.Look.READY
        }
        recordButton.isEnabled = hasAPIKey && state != DictationController.State.TRANSCRIBING
        recordButton.alpha = if (recordButton.isEnabled) 1f else 0.5f
        recordButton.contentDescription =
            if (state == DictationController.State.RECORDING) "Stop dictating" else "Dictate"

        // Cleared as the meter appears rather than as it leaves, so the previous recording's bars
        // are never what a new one starts from. Gated on the alpha it is about to change, because
        // render() also runs mid-recording -- for a status message, say -- and clearing on every
        // pass would wipe the bars out from under the speaker.
        if (state == DictationController.State.RECORDING && meter.alpha == 0f) {
            meter.clearLevels()
        }
        meter.alpha = if (state == DictationController.State.RECORDING) 1f else 0f

        val line = message ?: when (state) {
            DictationController.State.RECORDING -> "Listening… tap to stop"
            // Named, not a bare spinner: after you stop talking the wait is dead time, and the user
            // needs to know what is consuming it and to retain a way out if the provider never
            // answers.
            DictationController.State.TRANSCRIBING -> "Transcribing…"
            else -> if (hasAPIKey) "Tap to dictate, or hold to talk" else ""
        }
        statusLabel.text = line
        statusLabel.setTextColor(
            themeColor(
                if (message != null && messageIsError) {
                    androidx.appcompat.R.attr.colorError
                } else {
                    com.google.android.material.R.attr.colorOnSurfaceVariant
                },
            ),
        )
        statusLabel.visibility = if (line.isEmpty()) View.GONE else View.VISIBLE

        cancelButton.visibility =
            if (state == DictationController.State.TRANSCRIBING) View.VISIBLE else View.GONE
        // Shown in place of the idle sentence, which is the sentence it replaces: with no key
        // "tap to dictate" is an instruction that cannot be followed.
        settingsLink.visibility = if (hasAPIKey) View.GONE else View.VISIBLE

        refreshMode()
    }

    /** The latest transcript and the pending count, both read from the same history pass. */
    private fun refreshHistory() {
        if (!::latestText.isInitialized) return
        service.history.configure(Settings.retention, Settings.keepAudio)
        val records = service.history.all()

        val latest = records.firstOrNull { it.status == DictationRecord.Status.COMPLETED }
        latestText.text = latest?.deliveredText.orEmpty()
        latestSection.visibility = if (latest == null) View.GONE else View.VISIBLE

        val waiting = records.count { it.canRetry }
        pendingButton.text = "$waiting waiting to send — retry"
        pendingButton.isEnabled = !Settings.apiKey.isNullOrBlank()
        pendingButton.visibility = if (waiting > 0) View.VISIBLE else View.GONE
    }

    // MARK: - Navigation

    private fun open(screen: Class<*>) {
        startActivity(Intent(this, screen))
    }

    private fun openSettings() {
        open(SettingsActivity::class.java)
    }

    private companion object {
        const val MENU_HISTORY = 1
        const val MENU_FILES = 2
        const val MENU_SETTINGS = 3
    }
}
