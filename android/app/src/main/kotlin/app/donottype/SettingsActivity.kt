package app.donottype

import app.donottype.accessibility.ScreenReaderService
import app.donottype.core.DictationRecord
import app.donottype.core.DictationService
import app.donottype.core.Fidelity
import app.donottype.core.HistoryQuery
import app.donottype.core.GroundingSupport
import app.donottype.core.InputPart
import app.donottype.core.PerformanceStats
import app.donottype.core.ProviderFactory
import app.donottype.core.ProviderKind
import app.donottype.core.RetentionPolicy
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.provider.Settings as AndroidSettings
import android.text.InputType
import android.text.format.Formatter
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

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

    private lateinit var apiKeyField: EditText
    private lateinit var modelField: EditText
    private lateinit var groundingNote: TextView
    private lateinit var fallbackKeyField: EditText
    private lateinit var fallbackDelayField: EditText
    private lateinit var fallbackNote: TextView
    private lateinit var statusLabel: TextView
    private lateinit var connectionLabel: TextView
    private lateinit var historyContainer: LinearLayout
    private lateinit var historySummary: TextView
    private lateinit var searchField: EditText
    private var query = HistoryQuery()

    private val service by lazy { DictationService(this) }

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
    }

    private fun buildLayout(): ScrollView {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(HORIZONTAL_PADDING, TOP_PADDING, HORIZONTAL_PADDING, BOTTOM_PADDING)
        }

        column.addView(heading("DoNotType", 24f))
        column.addView(
            body(
                "Transcribes what you said, not a tidied-up version of it. Grounded in what is on "
                    + "your screen so names and technical terms are spelled the way you see them."
            )
        )

        // ---- Setup ----
        column.addView(sectionTitle("Setup"))
        statusLabel = body("").apply { setTypeface(Typeface.MONOSPACE) }
        column.addView(statusLabel)

        column.addView(
            button("Grant microphone access") {
                ActivityCompat.requestPermissions(
                    this, arrayOf(Manifest.permission.RECORD_AUDIO), 1,
                )
            }
        )
        column.addView(
            button("Enable the keyboard") {
                startActivity(Intent(AndroidSettings.ACTION_INPUT_METHOD_SETTINGS))
            }
        )
        column.addView(
            button("Enable screen grounding (optional)") {
                startActivity(Intent(AndroidSettings.ACTION_ACCESSIBILITY_SETTINGS))
            }
        )

        // ---- Provider ----
        column.addView(sectionTitle("Provider"))
        column.addView(
            body("Calls go straight to the provider with your key. Nothing routes through a server of ours.")
        )
        column.addView(buildProviderPicker())

        // Stated rather than left to be discovered: a recognition service silently disables screen
        // grounding and the rewrite path, and neither control would otherwise say so.
        groundingNote = body("")
        column.addView(groundingNote)


        apiKeyField = EditText(this).apply {
            hint = "API key"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setText(Settings.apiKey.orEmpty())
        }
        column.addView(apiKeyField)

        modelField = EditText(this).apply {
            hint = "Model"
            setText(Settings.model)
        }
        column.addView(modelField)

        column.addView(
            button("Save") {
                // Keys and models are stored per provider, so this writes to whichever one is
                // selected rather than to a single shared slot.
                Settings.apiKey = apiKeyField.text.toString().trim()
                Settings.model = modelField.text.toString().trim()
                    .ifEmpty { Settings.provider.defaultModel }
                modelField.setText(Settings.model)
                Toast.makeText(this, "Saved", Toast.LENGTH_SHORT).show()
                refreshStatus()
            }
        )

        connectionLabel = body("")
        column.addView(connectionLabel)
        column.addView(button("Test connection") { testConnection() })

        // ---- Fallback ----
        // Its own section because it has its own key: the pairing only works when both are
        // configured, and a second key buried under the first one's field is how someone ends up
        // with a fallback that silently never fires.
        column.addView(sectionTitle("Fallback"))
        column.addView(buildFallbackPicker())
        fallbackKeyField = EditText(this).apply {
            hint = "Fallback API key"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setText(Settings.fallbackProvider?.let { Settings.keyFor(it) }.orEmpty())
        }
        column.addView(fallbackKeyField)

        fallbackDelayField = EditText(this).apply {
            hint = "Start it after (seconds)"
            inputType = InputType.TYPE_CLASS_NUMBER
            setText(Settings.fallbackAfterSeconds.toString())
        }
        column.addView(fallbackDelayField)

        column.addView(
            button("Save fallback") {
                Settings.fallbackProvider?.let {
                    Settings.setKey(it, fallbackKeyField.text.toString().trim())
                }
                Settings.fallbackAfterSeconds =
                    fallbackDelayField.text.toString().toIntOrNull() ?: 8
                fallbackDelayField.setText(Settings.fallbackAfterSeconds.toString())
                Toast.makeText(this, "Saved", Toast.LENGTH_SHORT).show()
                refreshProviderNotes()
            }
        )
        fallbackNote = body("")
        column.addView(fallbackNote)

        // ---- Dictation ----
        column.addView(sectionTitle("Fidelity"))
        column.addView(buildFidelityPicker())
        column.addView(
            body("Even Tidy only changes typography. None of these reword you.")
        )

        // ---- Grounding ----
        column.addView(sectionTitle("Screen grounding"))
        column.addView(
            Switch(this).apply {
                text = "Send screen context"
                isChecked = Settings.groundingEnabled
                setOnCheckedChangeListener { _, checked -> Settings.groundingEnabled = checked }
            }
        )
        column.addView(
            body(
                "Read only while you dictate, never stored. Sent as-is — no vocabulary list, no "
                    + "dictionary. It may correct spelling, never the words you said."
            )
        )

        // ---- History ----
        column.addView(sectionTitle("History"))
        column.addView(buildRetentionPicker())
        column.addView(
            Switch(this).apply {
                text = "Keep audio for successful dictations"
                isChecked = Settings.keepAudio
                setOnCheckedChangeListener { _, checked ->
                    Settings.keepAudio = checked
                    refreshHistory()
                }
            }
        )
        column.addView(
            body(
                "Failed dictations always keep their audio until they succeed, whatever this is "
                    + "set to — otherwise Retry could not work."
            )
        )

        // Search sits above the list because it is the reason history is kept at all.
        searchField = EditText(this).apply {
            hint = "Search transcripts, errors, apps"
            addTextChangedListener(object : android.text.TextWatcher {
                override fun afterTextChanged(s: android.text.Editable?) {
                    query = query.copy(text = s?.toString().orEmpty())
                    refreshHistory()
                }
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
            })
        }
        column.addView(searchField)

        column.addView(
            Spinner(this).apply {
                val filters = HistoryQuery.StatusFilter.entries
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
        )

        historySummary = body("")
        column.addView(historySummary)
        column.addView(button("Retry all failed") { retryAll() })

        historyContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(historyContainer)

        // ---- Recordings ----
        // The offline half. The keyboard covers speech you are about to make; this covers the
        // voice memo you already have.
        column.addView(sectionTitle("Recordings"))
        column.addView(
            body(
                "Transcribe a recording you already have — a voice memo, a call, a file someone "
                    + "sent you. Verbatim, rewritten, or summarised."
            )
        )
        column.addView(
            button("Transcribe a recording…") {
                startActivity(Intent(this, FileTranscriptionActivity::class.java))
            }.also { it.contentDescription = "transcribe-recording" }
        )

        // ---- Diagnostics ----
        column.addView(sectionTitle("Diagnostics"))
        column.addView(
            body(
                "Logcat needs a cable and a computer, which rules it out for the person who has "
                    + "the problem. This is the same record, on the device, with a share button."
            )
        )
        column.addView(
            button("Logs") {
                startActivity(Intent(this, LogsActivity::class.java))
            }.also { it.contentDescription = "open-logs" }
        )

        // ---- Prompt ----
        // Editable because this is open-source software whose entire behaviour is a prompt; making
        // it readable but not editable would be an odd line to draw. One file at a time rather than
        // one box for everything, because the contract is twelve separate instructions — and a
        // single buffer holding all of them is how the shipped text and the documentation about it
        // came to live in the same place, with a marker convention as the only thing telling them
        // apart.
        column.addView(sectionTitle("Prompt"))
        column.addView(
            body(
                "The transcription contract, one part per file. Everything in the box below is "
                    + "sent in full. Editing a part invalidates the measured numbers in the "
                    + "project's changelog, which describe the shipped text."
            )
        )

        val parts = PromptPart.all
        var selectedPart = parts.first()
        val promptEditor = EditText(this).apply {
            setTypeface(Typeface.MONOSPACE)
            textSize = 10f
            minLines = 8
            maxLines = 16
            gravity = Gravity.TOP or Gravity.START
        }
        val promptStatus = body("")

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
        column.addView(partPicker)
        column.addView(promptEditor)
        column.addView(promptStatus)
        loadPart()

        column.addView(
            button("Save part") {
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
            button("Restore this part") {
                PromptAssets.restoreDefault(this, selectedPart)
                loadPart()
                promptStatus.text = "Restored the shipped ${selectedPart.relativePath}."
            }
        )
        column.addView(
            button("Restore every part") {
                PromptAssets.restoreAll(this)
                loadPart()
                promptStatus.text = "Restored every part to the shipped contract."
            }
        )

        column.addView(
            button("Delete all history") {
                service.history.deleteAll()
                refreshHistory()
            }
        )

        return ScrollView(this).apply {
            addView(column)
            // Android 15 draws every app edge to edge whether it asked to or not, and a layout
            // built in code gets no insets applied for it. Without this the heading sits behind
            // the status bar and the last row behind the navigation bar -- which is exactly how
            // this screen looked on an API 35 device.
            //
            // The padding goes on the scroll view rather than on the column inside it, so that
            // clipToPadding keeps scrolled rows out from under the bars too. Padding the column
            // fixes only the resting position: scroll down and the text runs under the clock.
            ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
                val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                insets
            }
        }
    }

    // MARK: - Sections

    /**
     * Switching provider reloads the key and model fields, because both are stored per provider.
     * Carrying one provider's key into another's field would look like it had been saved.
     */
    private fun buildProviderPicker(): Spinner {
        val kinds = ProviderKind.entries
        return Spinner(this).apply {
            adapter = ArrayAdapter(
                this@SettingsActivity,
                android.R.layout.simple_spinner_dropdown_item,
                kinds.map { it.displayName },
            )
            setSelection(kinds.indexOf(Settings.provider).coerceAtLeast(0))
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                    val chosen = kinds[position]
                    if (chosen == Settings.provider) return
                    Settings.provider = chosen
                    apiKeyField.setText(Settings.apiKey.orEmpty())
                    apiKeyField.hint = "${chosen.displayName} API key"
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
        val choices = listOf<ProviderKind?>(null) + ProviderKind.entries.filter { it != Settings.provider }
        return Spinner(this).apply {
            adapter = ArrayAdapter(
                this@SettingsActivity,
                android.R.layout.simple_spinner_dropdown_item,
                choices.map { it?.displayName ?: "None" },
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
        fallbackKeyField.visibility = if (fallback != null) View.VISIBLE else View.GONE
        fallbackDelayField.visibility = if (fallback != null) View.VISIBLE else View.GONE
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
            // A recognition backend rejects a text-only request by design, so probing one with the
            // text round trip would report a working key as broken. It gets a fraction of a second
            // of silence instead — enough to exercise auth, the URL and the response shape, which
            // is all this button claims to check.
            val parts = if (client.grounding() is GroundingSupport.Multimodal) {
                listOf(InputPart.Text("Pretend the audio said: ok. Transcribe it."))
            } else {
                listOf(InputPart.Audio(silentProbeWav(), "audio/wav"))
            }

            connectionLabel.text = runCatching {
                client.transcribe("You are a transcription engine.", parts)
            }.fold(
                onSuccess = { "✓ Reachable, key accepted" },
                onFailure = { error ->
                    // Silence transcribes to nothing, and on a recogniser that is the correct
                    // answer — it proves the round trip worked.
                    if (error.message?.contains("no output", ignoreCase = true) == true) {
                        "✓ Reachable, key accepted"
                    } else {
                        "✗ ${error.message}"
                    }
                },
            )
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
        records.forEach { historyContainer.addView(historyRow(it)) }
    }

    private fun historyRow(record: DictationRecord): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 12, 0, 12)
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
                        textSize = 13f
                        setTextColor(
                            if (record.status == DictationRecord.Status.COMPLETED) Color.DKGRAY
                            else Color.parseColor("#B23A2F")
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
                            textSize = 11f
                            setTextColor(
                                if ((record.latencyMillis ?: 0) > 8_000) Color.parseColor("#B26A00")
                                else Color.GRAY
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
                Button(this).apply {
                    text = "Retry"
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
            Button(this).apply {
                text = "✕"
                contentDescription = "Delete this transcript"
                setOnClickListener {
                    service.history.delete(record.id)
                    refreshHistory()
                }
            }
        )
        return row
    }

    private fun refreshStatus() {
        val checks = listOf(
            "API key" to !Settings.apiKey.isNullOrBlank(),
            "Microphone" to (
                ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                    == PackageManager.PERMISSION_GRANTED
                ),
            "Screen grounding" to (ScreenReaderService.instance != null),
        )
        statusLabel.text = checks.joinToString("\n") { (label, ok) ->
            "${if (ok) "✓" else "○"}  $label"
        }
    }

    // MARK: - Tiny view helpers

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

    private companion object {
        const val HORIZONTAL_PADDING = 56
        const val TOP_PADDING = 64
        const val BOTTOM_PADDING = 96
    }
}
