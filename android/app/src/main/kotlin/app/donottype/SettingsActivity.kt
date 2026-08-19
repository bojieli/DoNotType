package app.donottype

import app.donottype.accessibility.ScreenReaderService
import app.donottype.core.DictationRecord
import app.donottype.core.DictationService
import app.donottype.core.Fidelity
import app.donottype.core.HistoryQuery
import app.donottype.core.InputPart
import app.donottype.core.PerformanceStats
import app.donottype.core.PersonalDictionary
import app.donottype.core.ProviderFactory
import app.donottype.core.ProviderKind
import app.donottype.core.RetentionPolicy
import app.donottype.core.RewriteAvailability
import app.donottype.core.RewriteStyle
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.provider.Settings as AndroidSettings
import android.text.InputType
import android.text.format.Formatter
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import app.donottype.ui.caption
import app.donottype.ui.card
import app.donottype.ui.cardHolding
import app.donottype.ui.controlRow
import app.donottype.ui.divider
import app.donottype.ui.fieldContainer
import app.donottype.ui.dp
import app.donottype.ui.monospace
import app.donottype.ui.primaryButton
import app.donottype.ui.screenScaffold
import app.donottype.ui.screenSubtitle
import app.donottype.ui.screenTitle
import app.donottype.ui.sectionFooter
import app.donottype.ui.sectionTitle
import app.donottype.ui.setRowVisible
import app.donottype.ui.settingRow
import app.donottype.ui.setupRow
import app.donottype.ui.switchRow
import app.donottype.ui.textButton
import app.donottype.ui.themeColor
import app.donottype.ui.tonalButton
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * Setup, settings and history.
 *
 * Also the only place the microphone permission can be granted: an `InputMethodService` cannot
 * request a runtime permission itself, so the keyboard sends people here.
 *
 * Built in code rather than XML layouts — this is a settings list, and a layout file per section
 * would be more indirection than the screen is worth.
 */
class SettingsActivity : AppCompatActivity() {

    private lateinit var apiKeyField: TextInputEditText
    private lateinit var apiKeyLayout: TextInputLayout
    private lateinit var modelField: TextInputEditText
    private lateinit var modelLayout: TextInputLayout
    private lateinit var recommendationNote: TextView
    private lateinit var groundingNote: TextView
    private lateinit var rewriteStylePicker: Spinner
    private lateinit var rewriteNote: TextView
    private lateinit var fallbackKeyField: TextInputEditText
    private lateinit var fallbackKeyLayout: TextInputLayout
    private lateinit var fallbackDelayField: TextInputEditText
    private lateinit var fallbackDelayLayout: TextInputLayout
    /** Held so the pair can be hidden with the hairline above them when there is no fallback. */
    private lateinit var fallbackKeyRow: LinearLayout
    private lateinit var fallbackDelayRow: LinearLayout
    private lateinit var fallbackNote: TextView
    /** The three setup steps and their state, rebuilt by refreshStatus(). */
    private lateinit var setupContainer: LinearLayout
    private lateinit var connectionLabel: TextView
    private lateinit var historyContainer: LinearLayout
    private lateinit var historySummary: TextView
    private lateinit var searchField: TextInputEditText
    private lateinit var searchFieldLayout: TextInputLayout
    private lateinit var dictionaryContainer: LinearLayout
    private lateinit var dictionaryEntry: TextInputEditText
    private lateinit var dictionaryEntryLayout: TextInputLayout
    private lateinit var dictionaryStatus: TextView
    private var query = HistoryQuery()

    private val settingsTransfer = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode == RESULT_OK) recreate()
    }

    private val service by lazy { DictationService(this) }
    private val dictionaryPicker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@registerForActivityResult
        dictionaryStatus.text = runCatching {
            val data = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                ?: error("Could not read that file.")
            val imported = PersonalDictionary.entriesFromCsv(data)
            val current = Settings.personalDictionaryTerms()
            val seen = current.mapTo(mutableSetOf()) { it.lowercase() }
            val additions = imported.filter { seen.add(it.lowercase()) }
            if (current.size + additions.size > PersonalDictionary.MAX_TERMS) {
                throw PersonalDictionary.ValidationException(
                    "The dictionary can contain at most ${PersonalDictionary.MAX_TERMS} entries.",
                )
            }
            Settings.dictionaryTerms = Settings.dictionaryTerms + additions
            refreshDictionary()
            "Imported ${additions.size} new entries."
        }.getOrElse { it.message ?: "That dictionary could not be imported." }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Settings.initialise(this)
        setContentView(buildLayout())

        // Edge to edge means the app owns the area behind the status bar, including whether its
        // clock and icons are drawn dark or light. Left alone they stay light, which on this
        // screen's light background made them almost invisible.
        val night = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = !night
            isAppearanceLightNavigationBars = !night
        }
    }

    override fun onResume() {
        super.onResume()
        refreshProviderNotes()
        refreshStatus()
        refreshHistory()
        if (::dictionaryContainer.isInitialized) refreshDictionary()
    }

    private fun buildLayout(): ScrollView = screenScaffold { column ->
        column.addView(screenTitle("DoNotType"))
        column.addView(
            screenSubtitle(
                "Transcribes what you said, not a tidied-up version of it. Grounded in what is on "
                    + "your screen so names and technical terms are spelled the way you see them."
            )
        )

        // Transfer is deliberately first. An existing user should be able to configure a new
        // phone with one scan, without scrolling through every individual setting first.
        column.addView(sectionTitle("Set up from another device"))
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
                }.also { it.contentDescription = "scan-settings-qr" },
                settingRow(
                    "Import, export, or edit settings",
                    "Paste a document, or import a QR image or JSON file.",
                ) {
                    settingsTransfer.launch(Intent(this, SettingsTransferActivity::class.java))
                }.also { it.contentDescription = "open-settings-transfer" },
            )
        )
        column.addView(
            sectionFooter("Imported values are shown for review before anything changes.")
        )

        // ---- Setup ----
        column.addView(sectionTitle("First-time setup"))
        // The checklist and its actions, rather than a block of monospace ticks. Each row says
        // what the step is for and carries its own state, which refreshStatus() rewrites -- a
        // screen that reports "○ Microphone" and nothing else leaves the reader to work out both
        // what it wants and what to do about it.
        setupContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(cardHolding(setupContainer))
        refreshStatus()

        column.addView(
            tonalButton("Grant microphone access") {
                ActivityCompat.requestPermissions(
                    this, arrayOf(Manifest.permission.RECORD_AUDIO), 1,
                )
            }
        )
        column.addView(
            tonalButton("Enable the keyboard") {
                startActivity(Intent(AndroidSettings.ACTION_INPUT_METHOD_SETTINGS))
            }
        )
        column.addView(
            tonalButton("Enable screen grounding (optional)") {
                startActivity(Intent(AndroidSettings.ACTION_ACCESSIBILITY_SETTINGS))
            }
        )
        column.addView(
            sectionFooter(
                "Grant the microphone, enable the DoNotType keyboard, then add and save an API "
                    + "key below. Screen grounding is optional."
            )
        )

        // ---- Provider ----
        column.addView(sectionTitle("Provider"))

        apiKeyField = TextInputEditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setText(Settings.apiKey.orEmpty())
        }
        apiKeyLayout = fieldContainer("API key", apiKeyField, password = true)

        modelField = TextInputEditText(this).apply { setText(Settings.model) }
        modelLayout = fieldContainer("Model", modelField)

        column.addView(
            card(
                controlRow("Service", buildProviderPicker()),
                controlRow(null, apiKeyLayout),
                controlRow(null, modelLayout),
            )
        )

        // What the choice buys, for the two there is a recommendation for. Above the note below
        // it, because someone who has just been told two entries are recommended is asking which.
        recommendationNote = sectionFooter("")
        column.addView(recommendationNote)
        // Stated rather than left to be discovered: a recognition service silently disables screen
        // grounding and the rewrite path, and neither control would otherwise say so.
        groundingNote = sectionFooter("")
        column.addView(groundingNote)

        column.addView(
            primaryButton("Save") {
                // Keys and models are stored per provider, so this writes to whichever one is
                // selected rather than to a single shared slot.
                val keySaved = Settings.setKey(
                    Settings.provider, apiKeyField.text.toString().trim())
                Settings.model = modelField.text.toString().trim()
                    .ifEmpty { Settings.provider.defaultModel }
                modelField.setText(Settings.model)
                Toast.makeText(
                    this,
                    if (keySaved) "Saved" else "API key could not be stored securely",
                    Toast.LENGTH_LONG,
                ).show()
                refreshStatus()
            }
        )
        column.addView(tonalButton("Test connection") { testConnection() })
        connectionLabel = monospace("")
        column.addView(connectionLabel)
        column.addView(
            sectionFooter(
                "Calls go straight to the provider with your key. Nothing routes through a "
                    + "server of ours."
            )
        )

        // ---- Fallback ----
        // Its own section because it has its own key: the pairing only works when both are
        // configured, and a second key buried under the first one's field is how someone ends up
        // with a fallback that silently never fires.
        column.addView(sectionTitle("Fallback"))
        fallbackKeyField = TextInputEditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setText(Settings.fallbackProvider?.let { Settings.keyFor(it) }.orEmpty())
        }
        fallbackKeyLayout =
            fieldContainer("Fallback API key", fallbackKeyField, password = true)

        fallbackDelayField = TextInputEditText(this).apply {
            inputType = InputType.TYPE_CLASS_NUMBER
            setText(Settings.fallbackAfterSeconds.toString())
        }
        fallbackDelayLayout =
            fieldContainer("Start it after (seconds)", fallbackDelayField)

        fallbackKeyRow = controlRow(null, fallbackKeyLayout)
        fallbackDelayRow = controlRow(null, fallbackDelayLayout)
        column.addView(
            card(
                controlRow("Second service", buildFallbackPicker()),
                fallbackKeyRow,
                fallbackDelayRow,
            )
        )
        column.addView(
            tonalButton("Save fallback") {
                val keySaved = Settings.fallbackProvider?.let {
                    Settings.setKey(it, fallbackKeyField.text.toString().trim())
                } ?: true
                Settings.fallbackAfterSeconds =
                    fallbackDelayField.text.toString().toIntOrNull() ?: 8
                fallbackDelayField.setText(Settings.fallbackAfterSeconds.toString())
                Toast.makeText(
                    this,
                    if (keySaved) "Saved" else "Fallback key could not be stored securely",
                    Toast.LENGTH_LONG,
                ).show()
                refreshProviderNotes()
            }
        )
        fallbackNote = sectionFooter("")
        column.addView(fallbackNote)

        // ---- Dictation ----
        column.addView(sectionTitle("Fidelity"))
        column.addView(card(controlRow(null, buildFidelityPicker())))
        column.addView(
            sectionFooter("Even Tidy only changes typography. None of these reword you.")
        )

        // ---- Rewrite ----
        // The keyboard chooses only the operation. Its formatting policy belongs here, separately
        // from Fidelity, so "Dictate" is never presented as though it were a fourth writing style.
        column.addView(sectionTitle("Rewrite"))
        rewriteStylePicker = buildRewriteStylePicker()
        column.addView(card(controlRow("Rewrite style", rewriteStylePicker)))
        rewriteNote = sectionFooter("")
        column.addView(rewriteNote)

        // ---- Grounding ----
        column.addView(sectionTitle("Screen grounding"))
        column.addView(
            card(
                switchRow(
                    "Send screen context",
                    "Read only while you dictate, never stored.",
                    checked = Settings.groundingEnabled,
                ) { Settings.groundingEnabled = it },
            )
        )
        column.addView(
            sectionFooter(
                "Screen context stays separate from your explicit dictionary. It may correct "
                    + "spelling, never the words you said."
            )
        )

        // ---- Dictionary ----
        column.addView(sectionTitle("Personal dictionary"))
        dictionaryEntry = TextInputEditText(this)
        dictionaryEntryLayout = fieldContainer("Word or phrase", dictionaryEntry)
        column.addView(
            card(
                switchRow(
                    "Learn spelling corrections after dictation",
                    "For one minute after insertion, the keyboard watches only that same editor.",
                    checked = Settings.learnDictionaryFromEdits,
                ) { Settings.learnDictionaryFromEdits = it },
                controlRow(null, dictionaryEntryLayout),
            )
        )
        column.addView(tonalButton("Add entry") { addDictionaryEntry() })
        column.addView(
            tonalButton("Import CSV…") {
                dictionaryPicker.launch(arrayOf("text/csv", "text/plain", "application/csv"))
            },
        )
        dictionaryStatus = caption("")
        column.addView(dictionaryStatus)
        dictionaryContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(cardHolding(dictionaryContainer))
        refreshDictionary()
        column.addView(
            sectionFooter(
                "Names, jargon and preferred capitalisation. The same bounded list is sent to "
                    + "every compatible backend; number-bearing entries never enter a bare "
                    + "speech-recognition hint channel. Password fields, additions, deletions, "
                    + "numbers and ordinary rewrites are never learned from.",
            ),
        )

        // ---- History ----
        column.addView(sectionTitle("History"))

        // Search sits above the list because it is the reason history is kept at all.
        searchField = TextInputEditText(this).apply {
            addTextChangedListener(object : android.text.TextWatcher {
                override fun afterTextChanged(s: android.text.Editable?) {
                    query = query.copy(text = s?.toString().orEmpty())
                    refreshHistory()
                }
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
            })
        }
        searchFieldLayout =
            fieldContainer("Search transcripts, errors, apps", searchField)

        column.addView(
            card(
                controlRow(null, searchFieldLayout),
                controlRow("Show", buildStatusFilterPicker()),
                controlRow("Keep for", buildRetentionPicker()),
                switchRow(
                    "Keep audio for successful dictations",
                    "Failed dictations always keep theirs until they succeed.",
                    checked = Settings.keepAudio,
                ) {
                    Settings.keepAudio = it
                    refreshHistory()
                },
            )
        )

        historySummary = caption("")
        column.addView(historySummary)
        column.addView(tonalButton("Retry all failed") { retryAll() })

        historyContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(cardHolding(historyContainer))
        column.addView(
            sectionFooter(
                "Whatever Keep audio is set to, a failed dictation holds on to its recording — "
                    + "otherwise Retry could not work."
            )
        )

        // ---- Recordings ----
        // The offline half. The keyboard covers speech you are about to make; this covers the
        // voice memo you already have.
        column.addView(sectionTitle("Recordings"))
        column.addView(
            tonalButton("Transcribe a recording…") {
                startActivity(Intent(this, FileTranscriptionActivity::class.java))
            }.also { it.contentDescription = "transcribe-recording" }
        )
        column.addView(
            sectionFooter(
                "Transcribe a recording you already have — a voice memo, a call, a file someone "
                    + "sent you. Verbatim, rewritten, or summarised."
            )
        )

        // ---- Diagnostics ----
        column.addView(sectionTitle("Diagnostics"))
        column.addView(
            tonalButton("Logs") {
                startActivity(Intent(this, LogsActivity::class.java))
            }.also { it.contentDescription = "open-logs" }
        )
        column.addView(
            sectionFooter(
                "Logcat needs a cable and a computer, which rules it out for the person who has "
                    + "the problem. This is the same record, on the device, with a share button."
            )
        )

        // ---- Prompt ----
        // Editable because this is open-source software whose entire behaviour is a prompt; making
        // it readable but not editable would be an odd line to draw. One file at a time rather than
        // one box for everything, because the contract is twelve separate instructions — and a
        // single buffer holding all of them is how the shipped text and the documentation about it
        // came to live in the same place, with a marker convention as the only thing telling them
        // apart.
        column.addView(sectionTitle("Prompt"))

        val parts = PromptPart.all
        var selectedPart = parts.first()
        val promptEditor = TextInputEditText(this).apply {
            setTypeface(Typeface.MONOSPACE)
            textSize = 11f
            minLines = 8
            maxLines = 16
            gravity = Gravity.TOP or Gravity.START
        }
        val promptStatus = caption("")

        fun loadPart() {
            promptEditor.setText(PromptAssets.editableText(this, selectedPart))
            val edited = if (PromptAssets.isCustom(this, selectedPart)) "edited" else "shipped"
            promptStatus.text =
                "${selectedPart.relativePath} ($edited) — ${selectedPart.summaryLine}"
        }

        val partPicker = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@SettingsActivity,
                android.R.layout.simple_spinner_dropdown_item,
                parts.map { "${it.group} · ${it.label}" },
            )
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(p: AdapterView<*>?, v: View?, position: Int, id: Long) {
                    selectedPart = parts[position]
                    loadPart()
                }

                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }.also { it.contentDescription = "prompt-part" }

        column.addView(
            card(
                controlRow("Part", partPicker),
                controlRow(null, fieldContainer("Contract text", promptEditor)),
            )
        )
        column.addView(promptStatus)
        loadPart()

        column.addView(
            primaryButton("Save part") {
                promptStatus.text = runCatching {
                    PromptAssets.saveCustomPrompt(this, promptEditor.text.toString(), selectedPart)
                }.fold(
                    onSuccess = {
                        "Saved ${selectedPart.relativePath}. Re-measure before trusting the " +
                            "published numbers."
                    },
                    onFailure = { it.message ?: "The part could not be saved." },
                )
            }
        )
        // Restores the selected part only. The others keep whatever they are, which is the point of
        // per-part overrides: editing one clause should not pin the whole contract.
        column.addView(
            tonalButton("Restore this part") {
                PromptAssets.restoreDefault(this, selectedPart)
                loadPart()
                promptStatus.text = "Restored the shipped ${selectedPart.relativePath}."
            }
        )
        column.addView(
            textButton("Restore every part") {
                PromptAssets.restoreAll(this)
                loadPart()
                promptStatus.text = "Restored every part to the shipped contract."
            }
        )
        column.addView(
            sectionFooter(
                "The transcription contract, one part per file. Everything in the box above is "
                    + "sent in full. Editing a part invalidates the measured numbers in the "
                    + "project's changelog, which describe the shipped text."
            )
        )

        // ---- About ----
        // Commit and build time come from BuildConfig (stamped per build in build.gradle.kts),
        // because "which build is this" is the first question a bug report has to answer.
        column.addView(sectionTitle("About"))
        // versionCode-as-int is deprecated, but longVersionCode would need an API 28 guard; not
        // worth one for a single display line.
        @Suppress("DEPRECATION")
        val versionLine = packageManager.getPackageInfo(packageName, 0).let {
            "${it.versionName} (${it.versionCode})"
        }
        column.addView(
            card(
                settingRow("Version", versionLine),
                settingRow(
                    "Build",
                    "${BuildConfig.BUILD_COMMIT} · ${BuildConfig.BUILD_TIMESTAMP}",
                ),
                settingRow("GitHub", "github.com/bojieli/DoNotType") {
                    startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/bojieli/DoNotType"))
                    )
                },
                settingRow("Open source licenses") { showLicenseNotices() },
            )
        )

        column.addView(
            textButton("Delete all history") {
                service.history.deleteAll()
                refreshHistory()
            }
        )
    }

    /** The history status filter, which used to be an unlabelled spinner under the search box. */
    private fun buildStatusFilterPicker(): Spinner {
        val filters = HistoryQuery.StatusFilter.entries
        return Spinner(this).apply {
            adapter = ArrayAdapter(
                this@SettingsActivity,
                android.R.layout.simple_spinner_dropdown_item,
                filters.map { it.label },
            )
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) {
                    query = query.copy(status = filters[pos])
                    refreshHistory()
                }
                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }
    }

    private fun addDictionaryEntry() {
        dictionaryStatus.text = runCatching {
            val term = PersonalDictionary.normalize(dictionaryEntry.text.toString())
            val current = Settings.personalDictionaryTerms()
            if (current.any { it.equals(term, ignoreCase = true) }) {
                throw PersonalDictionary.ValidationException("“$term” is already in the dictionary.")
            }
            if (current.size >= PersonalDictionary.MAX_TERMS) {
                throw PersonalDictionary.ValidationException(
                    "The dictionary can contain at most ${PersonalDictionary.MAX_TERMS} entries.",
                )
            }
            Settings.dictionaryTerms = Settings.dictionaryTerms + term
            dictionaryEntry.text?.clear()
            refreshDictionary()
            "Added “$term”."
        }.getOrElse { it.message ?: "That entry could not be added." }
    }

    private fun refreshDictionary() {
        if (!::dictionaryContainer.isInitialized) return
        dictionaryContainer.removeAllViews()
        var rows = 0
        fun addRow(term: String, learned: Boolean) {
            if (rows++ > 0) dictionaryContainer.addView(divider())
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                val padding = resources.getDimensionPixelSize(R.dimen.space_m)
                setPadding(padding, padding, padding, padding)
            }
            val editor = TextInputEditText(this).apply {
                setText(term)
                contentDescription = "dictionary-${if (learned) "learned" else "added"}-$term"
            }
            row.addView(
                fieldContainer(
                    if (learned) "Learned from an edit" else "Added by you",
                    editor,
                ),
            )
            val actions = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.END
            }
            actions.addView(textButton("Save") {
                dictionaryStatus.text = runCatching {
                    Settings.replaceDictionaryTerm(term, editor.text.toString(), learned)
                    refreshDictionary()
                    "Saved."
                }.getOrElse { it.message ?: "That entry could not be saved." }
            }.also { it.layoutParams = wrapContent() })
            actions.addView(textButton("Remove") {
                Settings.removeDictionaryTerm(term, learned)
                refreshDictionary()
                dictionaryStatus.text = "Removed “$term”."
            }.also { it.layoutParams = wrapContent() })
            row.addView(actions)
            dictionaryContainer.addView(row)
        }
        Settings.dictionaryTerms.forEach { addRow(it, false) }
        Settings.learnedDictionaryTerms.forEach { addRow(it, true) }
        dictionaryStatus.text =
            "${Settings.personalDictionaryTerms().size} of ${PersonalDictionary.MAX_TERMS} entries"
    }

    // MARK: - Sections

    /**
     * Switching provider reloads the key and model fields, because both are stored per provider.
     * Carrying one provider's key into another's field would look like it had been saved.
     */
    private fun buildProviderPicker(): Spinner {
        // Recommended order rather than declaration order, and every index below is a lookup into
        // this same list rather than an ordinal, so the two cannot drift apart.
        val kinds = ProviderKind.PICKER_ORDER
        return Spinner(this).apply {
            adapter = ArrayAdapter(
                this@SettingsActivity,
                android.R.layout.simple_spinner_dropdown_item,
                kinds.map { it.pickerLabel },
            )
            setSelection(kinds.indexOf(Settings.provider).coerceAtLeast(0))
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                    val chosen = kinds[position]
                    if (chosen == Settings.provider) return
                    Settings.provider = chosen
                    apiKeyField.setText(Settings.apiKey.orEmpty())
                    apiKeyLayout.hint = "${chosen.displayName} API key"
                    modelField.setText(Settings.model)
                    refreshProviderNotes()
                    refreshStatus()
                }

                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }
    }

    /**
     * Anything but the primary. A fallback identical to it would double the cost to no purpose.
     */
    private fun buildFallbackPicker(): Spinner {
        val choices =
            listOf<ProviderKind?>(null) + ProviderKind.PICKER_ORDER.filter { it != Settings.provider }
        return Spinner(this).apply {
            adapter = ArrayAdapter(
                this@SettingsActivity,
                android.R.layout.simple_spinner_dropdown_item,
                choices.map { it?.pickerLabel ?: "None" },
            )
            setSelection(choices.indexOf(Settings.fallbackProvider).coerceAtLeast(0))
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                    val chosen = choices[position]
                    if (chosen == Settings.fallbackProvider) return
                    Settings.fallbackProvider = chosen
                    // Keys are per provider, so switching reloads rather than carrying one
                    // backend's key into another's field.
                    fallbackKeyField.setText(chosen?.let { Settings.keyFor(it) }.orEmpty())
                    refreshProviderNotes()
                }

                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }
    }

    /** Says what the selected backend gives up, and hides controls it cannot honour. */
    private fun refreshProviderNotes() {
        val kind = Settings.provider

        // From the shared rule, so a phone and a laptop answer "can this rewrite" the same way.
        // Stated whether or not it can: a note that appears only on failure leaves the feature
        // undiscoverable in the ordinary case, which is how it came to look absent entirely.
        val availability = RewriteAvailability.resolve(kind) { !Settings.keyFor(it).isNullOrBlank() }
        rewriteStylePicker.isEnabled = availability.isAvailable
        rewriteNote.text = availability.reason
            ?: "Use the small Dictate/Rewrite switch on the keyboard before you speak. This " +
                "setting controls what Rewrite produces; Fidelity only cleans the transcript. " +
                "The verbatim transcript is kept either way."

        recommendationNote.text = kind.recommendationNote
        recommendationNote.visibility =
            if (recommendationNote.text.isNullOrEmpty()) View.GONE else View.VISIBLE

        groundingNote.text = when (kind) {
            // The gateway forwards audio correctly; this is a measured quality difference, and
            // the picker is where two identical-looking entries get chosen between.
            ProviderKind.OPENROUTER ->
                "Routes through a gateway. The same Gemini model measures worse this way than " +
                    "through Gemini directly — 2 to 5 regressions per suite run against 1 — so " +
                    "prefer the Gemini service unless you need a model Google does not serve."
            ProviderKind.MISTRAL ->
                "Transcription only — this service cannot read your screen, and has no " +
                    "spelling-hint channel either. It is the one that handles Mandarin and " +
                    "English together."
            // Louder than a trade-off note: this one predicts lost dictations. Deepgram returned
            // nothing for 44 of 68 Mandarin clips on the dictation corpus.
            ProviderKind.DEEPGRAM ->
                "⚠ Transcription only, and it cannot transcribe Chinese with autodetection — it " +
                    "returned nothing for 44 of 68 Mandarin clips. Choose another service if you " +
                    "dictate in Chinese."
            ProviderKind.XAI ->
                "Transcription only — this service cannot read your screen. Fidelity has two " +
                    "settings here rather than three."
            ProviderKind.GEMINI -> ""
        }
        groundingNote.visibility =
            if (groundingNote.text.isNullOrEmpty()) View.GONE else View.VISIBLE


        val fallback = Settings.fallbackProvider
        fallbackKeyRow.setRowVisible(fallback != null)
        fallbackDelayRow.setRowVisible(fallback != null)
        fallbackNote.text = if (fallback == null) {
            "Off. Worth turning on when the primary is accurate but its latency has a tail — the " +
                "first-party Gemini API answered one three-second clip in 5 s and the next in " +
                "61 s. The fallback bounds that wait; it does not improve a transcript the " +
                "primary would have got right."
        } else {
            "If ${Settings.provider.id} has not answered in ${Settings.fallbackAfterSeconds}s, " +
                "${fallback.id} starts alongside it and whichever finishes first is used. " +
                "History records which one served each dictation."
        }
    }

    private fun buildFidelityPicker(): RadioGroup {
        val descriptions = mapOf(
            Fidelity.RAW to "Raw — every um and false start",
            Fidelity.LIGHT to "Light — drop fillers, keep your words",
            Fidelity.TIDY to "Tidy — light, plus punctuation",
        )
        return RadioGroup(this).apply {
            orientation = RadioGroup.VERTICAL
            Fidelity.entries.forEach { fidelity ->
                addView(
                    RadioButton(this@SettingsActivity).apply {
                        text = descriptions[fidelity]
                        isChecked = Settings.fidelity == fidelity
                        setOnClickListener { Settings.fidelity = fidelity }
                    }
                )
            }
        }
    }

    private fun buildRewriteStylePicker(): Spinner {
        val styles = RewriteStyle.entries.filter { it.isRewrite }
        return Spinner(this).apply {
            adapter = ArrayAdapter(
                this@SettingsActivity,
                android.R.layout.simple_spinner_dropdown_item,
                styles.map { it.label },
            )
            setSelection(styles.indexOf(Settings.preferredRewriteStyle).coerceAtLeast(0))
            contentDescription = "rewrite-style"
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(
                    parent: AdapterView<*>?, view: View?, position: Int, id: Long,
                ) {
                    Settings.preferredRewriteStyle = styles[position]
                }

                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }
    }

    private fun buildRetentionPicker(): Spinner {
        val policies = RetentionPolicy.entries
        return Spinner(this).apply {
            adapter = ArrayAdapter(
                this@SettingsActivity,
                android.R.layout.simple_spinner_dropdown_item,
                policies.map { it.label },
            )
            setSelection(policies.indexOf(Settings.retention).coerceAtLeast(0))
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(p: AdapterView<*>?, v: View?, position: Int, id: Long) {
                    Settings.retention = policies[position]
                    refreshHistory()
                }

                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }
    }

    // MARK: - Actions

    private fun testConnection() {
        val key = Settings.apiKey
        if (key.isNullOrBlank()) {
            connectionLabel.text = "No API key set."
            return
        }
        connectionLabel.text = "Checking…"
        lifecycleScope.launch {
            val client = ProviderFactory.create(Settings.provider, key, Settings.model)
            // Audio, for every backend — the same shape a dictation sends. Model backends used to
            // get a text round trip, which a text-only relay or checkpoint answers perfectly well
            // before dropping the first real recording. See ProviderProbe.check in the Swift core,
            // which this mirrors.
            val parts = listOf(InputPart.Audio(silentProbeWav(), "audio/wav"))

            val started = android.os.SystemClock.elapsedRealtimeNanos()
            val result = runCatching {
                client.transcribe("You are a transcription engine.", parts)
            }
            val latency = connectionLatencyLabel(
                android.os.SystemClock.elapsedRealtimeNanos() - started,
            )
            connectionLabel.text = result.fold(
                onSuccess = { "✓ Reachable, key accepted · $latency" },
                onFailure = { error ->
                    // Silence transcribes to nothing, which is the correct answer and proves
                    // the round trip worked.
                    if (error.message?.contains("no output", ignoreCase = true) == true) {
                        "✓ Reachable, key accepted · $latency"
                    } else {
                        "✗ ${error.message} · $latency"
                    }
                },
            )
        }
    }

    private fun connectionLatencyLabel(nanoseconds: Long): String {
        val milliseconds = nanoseconds.coerceAtLeast(0) / 1_000_000.0
        return if (milliseconds < 1_000) {
            "${milliseconds.roundToInt()} ms"
        } else {
            String.format(java.util.Locale.ROOT, "%.2f s", milliseconds / 1_000)
        }
    }

    /**
     * A quarter-second of 16 kHz mono silence, built rather than shipped as an asset so the APK
     * does not carry a resource used by one button.
     */
    private fun silentProbeWav(): ByteArray {
        val sampleRate = 16_000
        val dataBytes = sampleRate / 4 * 2
        val out = java.io.ByteArrayOutputStream()
        fun ascii(value: String) = out.write(value.toByteArray(Charsets.US_ASCII))
        fun u32(value: Int) =
            out.write(byteArrayOf(value.toByte(), (value shr 8).toByte(), (value shr 16).toByte(), (value shr 24).toByte()))
        fun u16(value: Int) = out.write(byteArrayOf(value.toByte(), (value shr 8).toByte()))

        ascii("RIFF"); u32(36 + dataBytes); ascii("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        ascii("data"); u32(dataBytes)
        out.write(ByteArray(dataBytes))
        return out.toByteArray()
    }

    private fun retryAll() {
        lifecycleScope.launch {
            historySummary.text = "Retrying…"
            val (succeeded, failed) = service.retryAll()
            historySummary.text = "$succeeded succeeded, $failed still failing"
            refreshHistory()
        }
    }

    private fun refreshHistory() {
        service.history.configure(Settings.retention, Settings.keepAudio)
        val all = service.history.all()
        val records = query.apply(all)
        val retryable = all.count { it.canRetry }

        historySummary.text = buildString {
            if (records.size == all.size) {
                append("${all.size} dictation${if (all.size == 1) "" else "s"}")
            } else {
                append("${records.size} of ${all.size}")
            }
            if (retryable > 0) append(" · $retryable to retry")
            append(" · ")
            append(Formatter.formatShortFileSize(this@SettingsActivity, service.history.audioBytes()))

            // Hidden until three successes: a median of two samples is not a median.
            val stats = PerformanceStats.compute(all)
            if (stats.completed >= 3) {
                append("\n")
                append("Typical wait ${PerformanceStats.formatMillis(stats.medianLatencyMillis)}")
                append(" · slowest 5% ${PerformanceStats.formatMillis(stats.p95LatencyMillis)}")
                stats.successRate?.let { append(" · ${(it * 100).toInt()}% succeeded") }
                append(" · ${PerformanceStats.formatCount(stats.words)} words")
            }
        }

        // Rendered in full rather than truncated. A list capped at 20 with nothing said about it
        // reads as "this is your whole history" when it is not; the retention policy is what is
        // supposed to bound how much there is, not the view.
        historyContainer.removeAllViews()
        records.forEachIndexed { index, record ->
            if (index > 0) historyContainer.addView(divider())
            historyContainer.addView(historyRow(record))
        }
    }

    private fun historyRow(record: DictationRecord): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            val padding = resources.getDimensionPixelSize(R.dimen.space_m)
            setPadding(padding, resources.getDimensionPixelSize(R.dimen.space_s), padding,
                resources.getDimensionPixelSize(R.dimen.space_s))
            minimumHeight = resources.getDimensionPixelSize(R.dimen.row_min_height)
        }

        val marker = when (record.status) {
            DictationRecord.Status.COMPLETED -> "✓"
            DictationRecord.Status.FAILED -> "✗"
            DictationRecord.Status.PENDING -> "…"
        }

        // Transcript with its timing underneath. Per row rather than only in aggregate, because
        // "that one felt slow" is a claim the user should be able to check.
        row.addView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)

                addView(
                    TextView(this@SettingsActivity).apply {
                        text = "$marker  ${record.summary.take(90)}"
                        textSize = 14f
                        // Theme attributes rather than the hex literals this used to carry. Under
                        // a DayNight theme a fixed dark grey is unreadable at night, which is what
                        // "✓ …" rows looked like on a dark phone: dark grey on a dark surface.
                        setTextColor(
                            if (record.status == DictationRecord.Status.COMPLETED) {
                                themeColor(com.google.android.material.R.attr.colorOnSurface)
                            } else {
                                themeColor(com.google.android.material.R.attr.colorError)
                            }
                        )
                    }
                )

                val details = buildList {
                    record.latencyMillis?.let { add(PerformanceStats.formatMillis(it)) }
                    if (record.retryCount > 0) add("retried ${record.retryCount}×")
                    if (record.durationSeconds > 0) {
                        add("${PerformanceStats.formatSeconds(record.durationSeconds)} spoken")
                    }
                }
                if (details.isNotEmpty()) {
                    addView(
                        TextView(this@SettingsActivity).apply {
                            text = details.joinToString(" · ")
                            textSize = 12f
                            // Amber marks a wait long enough to have been noticed. It is a named
                            // colour with a night variant, not a hex literal, for the same reason
                            // as the line above.
                            setTextColor(
                                if ((record.latencyMillis ?: 0) > 8_000) {
                                    ContextCompat.getColor(context, R.color.dnt_warning)
                                } else {
                                    themeColor(
                                        com.google.android.material.R.attr.colorOnSurfaceVariant,
                                    )
                                }
                            )
                        }
                    )
                }
            }
        )

        // The point of the whole grounding argument: if the app reads your screen, you can read
        // what it read. On the row it belongs to, rather than on a screen you have to know exists.
        row.setOnClickListener { ContextInspector.show(this, record) }

        if (record.canRetry) {
            row.addView(
                textButton("Retry") {}.apply {
                    layoutParams = wrapContent()
                    setOnClickListener {
                        isEnabled = false
                        lifecycleScope.launch {
                            service.retry(record)
                            refreshHistory()
                        }
                    }
                }
            )
        }

        // Per-item delete: removing one transcript should not require removing all of them.
        row.addView(
            textButton("✕") {
                service.history.delete(record.id)
                refreshHistory()
            }.apply {
                layoutParams = wrapContent()
                contentDescription = "Delete this transcript"
            }
        )
        return row
    }

    /**
     * Rewrites the setup checklist.
     *
     * Every state here is one the app can actually observe, so none of them is the nullable third
     * case [setupRow] allows -- unlike iOS, where whether the keyboard is enabled is not something
     * the containing app can ask. The rows still go through the same builder, because that is
     * where the question mark lives if a future check turns out to be unanswerable.
     */
    private fun refreshStatus() {
        if (!::setupContainer.isInitialized) return
        val checks = listOf(
            Triple(
                "API key",
                "Saved on this device, sent only to the provider you chose.",
                !Settings.apiKey.isNullOrBlank(),
            ),
            Triple(
                "Microphone",
                "The keyboard cannot ask for this itself, so it asks here.",
                ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                    == PackageManager.PERMISSION_GRANTED,
            ),
            Triple(
                "Screen grounding",
                "Optional. Spells names the way they appear on your screen.",
                ScreenReaderService.instance != null,
            ),
        )
        setupContainer.removeAllViews()
        checks.forEachIndexed { index, (label, detail, ok) ->
            if (index > 0) setupContainer.addView(divider())
            setupContainer.addView(setupRow(label, detail, done = ok))
        }
    }

    /**
     * The app's own license plus the notices for what it ships, read from the assets the Gradle
     * `syncContract` task copies out of the repo root.
     *
     * A missing asset is skipped rather than failing the dialog: a notice that did not get
     * packaged must not hide the ones that did.
     */
    private fun showLicenseNotices() {
        fun asset(path: String): String? = runCatching {
            assets.open(path).bufferedReader().use { it.readText() }.trim()
        }.getOrNull()

        val text = listOf(
            "DoNotType license" to "LICENSE.txt",
            "Silero VAD" to "third-party/SILERO-VAD-NOTICE.txt",
            "Third-party notices" to "THIRD-PARTY-NOTICES.txt",
        ).mapNotNull { (header, path) ->
            asset(path)?.let { "$header\n${"-".repeat(header.length)}\n\n$it" }
        }.joinToString("\n\n\n")

        val message = TextView(this).apply {
            this.text = text
            textSize = 13f
            val horizontal = resources.getDimensionPixelSize(R.dimen.space_l)
            setPadding(horizontal, dp(12), horizontal, dp(12))
        }
        AlertDialog.Builder(this)
            .setTitle("Open source licenses")
            // A view rather than setMessage: the notices are long, and a message that long is
            // cramped without an explicit scroll container.
            .setView(ScrollView(this).apply { addView(message) })
            .setPositiveButton("Done", null)
            .show()
    }

    // MARK: - Tiny view helpers

    /**
     * For a control that sits beside another one rather than filling the row. The design system's
     * buttons are full width, which is right for an action that is the point of a section and
     * wrong for the pair at the end of a history row.
     */
    private fun wrapContent() = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
    )
}
