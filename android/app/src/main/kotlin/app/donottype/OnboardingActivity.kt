package app.donottype

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.provider.Settings as AndroidSettings
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope
import app.donottype.accessibility.ScreenReaderService
import app.donottype.core.ProviderKind
import app.donottype.core.ProviderProbe
import app.donottype.ui.card
import app.donottype.ui.cardHolding
import app.donottype.ui.controlRow
import app.donottype.ui.divider
import app.donottype.ui.fieldContainer
import app.donottype.ui.monospace
import app.donottype.ui.primaryButton
import app.donottype.ui.screenScaffold
import app.donottype.ui.screenSubtitle
import app.donottype.ui.screenTitle
import app.donottype.ui.sectionFooter
import app.donottype.ui.sectionTitle
import app.donottype.ui.settingRow
import app.donottype.ui.setupRow
import app.donottype.ui.textButton
import app.donottype.ui.themeColor
import com.google.android.material.button.MaterialButton
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import kotlinx.coroutines.launch

/**
 * The first launch: a setup flow rather than a record button that cannot work yet.
 *
 * Mirrors iOS's `InitialSetupView` (ios/App/SettingsView.swift), section for section and in the
 * same order, because the order is the argument. Transfer is first: an existing user configures a
 * new phone with one scan and never reads the rest. Then the provider, because transcription
 * cannot start without a key and every later step is wasted on someone who will not get past this
 * one. The permissions come last, in the order a new user meets them.
 *
 * Where it departs from iOS it is because Android answers a question iOS cannot. Every permission
 * state here is observable — the keyboard's enablement included — so no row shows the "?" mark
 * that [setupRow] keeps for iOS's unanswerable keyboard question. And screen grounding is offered
 * here as an optional fourth step; iOS has nothing to offer in its place.
 *
 * This is deliberately not a trimmed copy of [SettingsActivity]. Everything on this screen is
 * something the app cannot work without, which is what makes it a flow rather than a settings
 * list: fidelity, fallback, retention and the dictionary all have working defaults, and a first
 * launch that asked about them would be asking the user to make five choices before making one.
 */
class OnboardingActivity : AppCompatActivity() {

    private lateinit var apiKeyField: TextInputEditText
    private lateinit var apiKeyLayout: TextInputLayout
    private lateinit var modelField: TextInputEditText
    private lateinit var connectionLabel: TextView
    private lateinit var testButton: MaterialButton
    private lateinit var finishButton: MaterialButton
    /** The permission checklist, rewritten by [refreshStatus] whenever the app is foregrounded. */
    private lateinit var setupContainer: LinearLayout

    private var isCheckingConnection = false

    /**
     * An imported profile can fill in the provider, model and key, so the fields are reloaded
     * from whatever the transfer screen wrote rather than left showing what was typed before it.
     */
    private val settingsTransfer = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode == RESULT_OK) recreate()
    }

    /**
     * A refusal that Android will not ask about again leads to the app's own settings page.
     *
     * `shouldShowRequestPermissionRationale` is false in two opposite cases — never asked, and
     * asked twice and refused — which is why it is read *after* a refusal rather than before an
     * ask: at that point false can only mean the second. Without this, the row's second tap would
     * silently do nothing, because the dialog it opens no longer appears.
     */
    private val microphone = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (!granted && !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)) {
            openAppSettings()
        }
        refreshStatus()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Settings.initialise(this)
        title = "Set up DoNotType"
        setContentView(buildLayout())

        // Edge to edge means the app owns the area behind the status bar, including whether its
        // clock and icons are drawn dark or light.
        val night = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = !night
            isAppearanceLightNavigationBars = !night
        }
    }

    override fun onResume() {
        super.onResume()
        // Two of the three steps are granted in Android's settings rather than here, so coming
        // back to the app is the only moment their state can be re-read.
        refreshStatus()
    }

    /**
     * Leaving counts as having been set up, whichever route out was taken.
     *
     * Overriding [finish] rather than the back press because there are four ways off this screen —
     * the button, Skip, the system back gesture, and a recents swipe that finishes the task — and
     * a flag written on only some of them shows the flow again to someone who deliberately left
     * it. iOS makes its sheet unskippable with `interactiveDismissDisabled`, which has no honest
     * Android equivalent: the back gesture belongs to the user, and a screen that swallows it is a
     * screen people force-quit. So the flow is skippable, and skipping it is remembered.
     *
     * Deliberately not conditional on having a key. Someone who leaves without one is telling us
     * they will configure it later, and showing them the same flow on every launch would be the
     * app disagreeing with them once per launch — which is why the dictation screen offers "Add an
     * API key in Settings" in place of its idle line.
     */
    override fun finish() {
        Settings.didCompleteInitialSetup = true
        super.finish()
    }

    // MARK: - Layout

    private fun buildLayout(): ScrollView = screenScaffold { column ->
        column.addView(screenTitle("Set up DoNotType"))
        column.addView(
            screenSubtitle(
                "Three things, then you can dictate: a key to transcribe with, the microphone, "
                    + "and the keyboard.",
            ),
        )

        buildTransferSection(column)
        buildProviderSection(column)
        buildPermissionSection(column)

        finishButton = primaryButton("Finish setup") { finish() }.apply {
            contentDescription = "finish-initial-setup"
        }
        column.addView(finishButton)
        column.addView(
            textButton("Skip for now") { finish() }.apply {
                contentDescription = "skip-initial-setup"
            },
        )
        column.addView(
            sectionFooter(
                "Everything here is also in Settings, so nothing chosen now is final.",
            ),
        )
    }

    /**
     * First, and before anything is asked: someone who already runs DoNotType elsewhere can fill
     * the whole provider section below with one scan, and should not have to read past a form
     * they are about to overwrite.
     */
    private fun buildTransferSection(column: LinearLayout) {
        column.addView(sectionTitle("Already use DoNotType?"))
        column.addView(
            card(
                settingRow(
                    "Scan settings QR code",
                    "Point the camera at the code another device is showing.",
                ) {
                    settingsTransfer.launch(
                        Intent(this, SettingsTransferActivity::class.java).putExtra(
                            SettingsTransferActivity.EXTRA_START_SCANNER, true,
                        ),
                    )
                }.also { it.contentDescription = "setup-scan-settings-qr" },
                settingRow(
                    "Import QR image or JSON",
                    "Read a code out of a screenshot, or open a settings file.",
                ) {
                    settingsTransfer.launch(Intent(this, SettingsTransferActivity::class.java))
                }.also { it.contentDescription = "setup-import-settings" },
            ),
        )
        column.addView(
            sectionFooter(
                "An imported profile can fill in the provider, model, and API key below.",
            ),
        )
    }

    private fun buildProviderSection(column: LinearLayout) {
        column.addView(sectionTitle("1. Configure transcription"))

        apiKeyField = TextInputEditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setText(Settings.apiKey.orEmpty())
            contentDescription = "setup-api-key"
            // Saved as it is typed rather than behind a Save button. There is no other screen to
            // carry the value to, and a setup flow whose Finish is disabled until you press a
            // different button first is the shape of a form people abandon.
            addTextChange { save() }
        }
        apiKeyLayout = fieldContainer("${Settings.provider.displayName} API key", apiKeyField, password = true)

        modelField = TextInputEditText(this).apply {
            setText(Settings.model)
            addTextChange { save() }
        }

        column.addView(
            card(
                controlRow("Service", buildProviderPicker()),
                controlRow(null, apiKeyLayout),
                controlRow(null, fieldContainer("Model", modelField)),
            ),
        )

        testButton = textButton("Test connection") { testConnection() }
        column.addView(testButton)
        // Never given a line limit: what a provider says when it refuses a key is the whole of
        // what the user has to act on, and it is what they will paste into a bug report.
        connectionLabel = monospace("").apply { visibility = View.GONE }
        column.addView(connectionLabel)
        column.addView(
            sectionFooter(
                "The key is encrypted on this device and sent only to the selected provider.",
            ),
        )
    }

    private fun buildPermissionSection(column: LinearLayout) {
        column.addView(sectionTitle("2. Enable dictation"))
        setupContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(cardHolding(setupContainer))
        column.addView(
            sectionFooter(
                "The keyboard cannot ask for the microphone itself, so this screen asks for it. "
                    + "Screen grounding is optional.",
            ),
        )
    }

    /**
     * Switching provider reloads the key and model fields, because both are stored per provider.
     * Carrying one provider's key into another's field would look like it had been saved.
     */
    private fun buildProviderPicker(): Spinner {
        val kinds = ProviderKind.PICKER_ORDER
        return Spinner(this).apply {
            adapter = ArrayAdapter(
                this@OnboardingActivity,
                android.R.layout.simple_spinner_dropdown_item,
                kinds.map { it.pickerLabel },
            )
            setSelection(kinds.indexOf(Settings.provider).coerceAtLeast(0))
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(p: AdapterView<*>?, v: View?, position: Int, id: Long) {
                    val chosen = kinds[position]
                    if (chosen == Settings.provider) return
                    Settings.provider = chosen
                    apiKeyField.setText(Settings.apiKey.orEmpty())
                    apiKeyLayout.hint = "${chosen.displayName} API key"
                    modelField.setText(Settings.model)
                    // The previous provider's verdict says nothing about this one's key.
                    showConnection(null)
                    refreshStatus()
                }

                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }
    }

    // MARK: - Steps

    /**
     * Rewrites the checklist and everything whose enablement depends on having a key.
     *
     * Every row is tappable and does the thing it names, which is the part iOS's `SetupRow` gets
     * right and a checklist of read-only ticks does not: a step that reports "not done" and leaves
     * the user to find the switch has told them about a problem and hidden its solution.
     */
    private fun refreshStatus() {
        if (!::setupContainer.isInitialized) return

        val steps = listOf(
            Step(
                title = "Allow microphone access",
                detail = "Required to record dictation in this app and in the keyboard.",
                done = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                    == PackageManager.PERMISSION_GRANTED,
                action = { requestMicrophone() },
            ),
            Step(
                title = "Add the DoNotType keyboard",
                // Unlike iOS, this is not a guess: an IME's enablement is readable from the app,
                // so the row states it rather than asking the user to confirm it by switching.
                detail = "Turn DoNotType on in Android's keyboard settings, then pick it with the "
                    + "keyboard switcher.",
                done = isKeyboardEnabled(),
                action = { startActivity(Intent(AndroidSettings.ACTION_INPUT_METHOD_SETTINGS)) },
            ),
            Step(
                title = "Enable screen grounding",
                detail = "Optional. Spells names and technical terms the way they appear on your "
                    + "screen.",
                done = ScreenReaderService.instance != null,
                action = { startActivity(Intent(AndroidSettings.ACTION_ACCESSIBILITY_SETTINGS)) },
            ),
        )

        setupContainer.removeAllViews()
        steps.forEachIndexed { index, step ->
            if (index > 0) setupContainer.addView(divider())
            setupContainer.addView(
                setupRow(step.title, step.detail, done = step.done).apply {
                    isClickable = true
                    isFocusable = true
                    setOnClickListener { step.action() }
                    contentDescription = step.title
                },
            )
        }

        val hasAPIKey = !Settings.apiKey.isNullOrBlank()
        if (::testButton.isInitialized) {
            testButton.isEnabled = hasAPIKey && !isCheckingConnection
        }
        if (::finishButton.isInitialized) {
            // The same rule as iOS's "Finish Setup": without a key there is nothing to finish,
            // and the two permissions are grantable later from a screen that says so.
            finishButton.isEnabled = hasAPIKey
            finishButton.alpha = if (hasAPIKey) 1f else 0.5f
        }
    }

    private data class Step(
        val title: String,
        val detail: String,
        val done: Boolean,
        val action: () -> Unit,
    )

    /**
     * Whether this app's keyboard is switched on in Android's settings.
     *
     * `getEnabledInputMethodList` rather than the "seen it appear" heuristic iOS is stuck with:
     * Android hands the containing app the list directly, so the answer is a fact rather than an
     * inference from the keyboard having once run.
     */
    private fun isKeyboardEnabled(): Boolean {
        val manager =
            getSystemService(INPUT_METHOD_SERVICE) as? android.view.inputmethod.InputMethodManager
        return manager?.enabledInputMethodList.orEmpty().any { it.packageName == packageName }
    }

    private fun requestMicrophone() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED
        ) {
            // Already granted; the row is a tick, and tapping a finished step should not reopen
            // a dialog that would only ever say yes again.
            return
        }
        microphone.launch(Manifest.permission.RECORD_AUDIO)
    }

    private fun openAppSettings() {
        startActivity(
            Intent(
                AndroidSettings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", packageName, null),
            ),
        )
    }

    // MARK: - Provider

    /**
     * Writes what is in the fields, on every keystroke.
     *
     * A model left empty falls back to the provider's own default rather than being stored blank —
     * an empty model field is how someone ends up sending "" to an endpoint that answers with a
     * 400 they cannot read.
     */
    private fun save() {
        Settings.setKey(Settings.provider, apiKeyField.text.toString().trim())
        Settings.model = modelField.text.toString().trim().ifEmpty { Settings.provider.defaultModel }
        refreshStatus()
    }

    private fun testConnection() {
        val key = Settings.apiKey
        if (key.isNullOrBlank()) return
        isCheckingConnection = true
        refreshStatus()
        connectionLabel.setTextColor(
            themeColor(com.google.android.material.R.attr.colorOnSurfaceVariant),
        )
        connectionLabel.text = "Checking…"
        connectionLabel.visibility = View.VISIBLE
        lifecycleScope.launch {
            // The same probe the settings screen runs, so the two never disagree about a key.
            val result = ProviderProbe.check(Settings.provider, key, Settings.model)
            isCheckingConnection = false
            showConnection(result)
            refreshStatus()
        }
    }

    /** The one place the connection line is written, so its colour never lags behind its text. */
    private fun showConnection(result: ProviderProbe.Result?) {
        if (!::connectionLabel.isInitialized) return
        connectionLabel.text = result?.message.orEmpty()
        connectionLabel.setTextColor(
            if (result?.accepted == false) {
                themeColor(androidx.appcompat.R.attr.colorError)
            } else {
                ContextCompat.getColor(this, R.color.dnt_success)
            },
        )
        connectionLabel.visibility = if (result == null) View.GONE else View.VISIBLE
    }

    private fun TextInputEditText.addTextChange(onChange: () -> Unit) {
        addTextChangedListener(
            object : android.text.TextWatcher {
                override fun afterTextChanged(s: android.text.Editable?) = onChange()
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
            },
        )
    }

    companion object {
        /**
         * Whether a launch should start here rather than at the dictation screen.
         *
         * Both halves matter, and they mirror iOS's `didCompleteInitialSetupV1` gate exactly. The
         * flag alone would show the flow forever to someone whose key arrived by QR import; the
         * key alone would show it again to anyone who cleared their key to switch providers.
         */
        fun isNeeded(): Boolean =
            !Settings.didCompleteInitialSetup && Settings.apiKey.isNullOrBlank()
    }
}
