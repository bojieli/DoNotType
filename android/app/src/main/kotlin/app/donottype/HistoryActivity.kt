package app.donottype

import app.donottype.core.DictationRecord
import app.donottype.core.DictationService
import app.donottype.core.HistoryQuery
import app.donottype.core.PerformanceStats
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.text.format.Formatter
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import app.donottype.ui.caption
import app.donottype.ui.card
import app.donottype.ui.cardHolding
import app.donottype.ui.controlRow
import app.donottype.ui.divider
import app.donottype.ui.fieldContainer
import app.donottype.ui.screenScaffold
import app.donottype.ui.screenSubtitle
import app.donottype.ui.screenTitle
import app.donottype.ui.sectionFooter
import app.donottype.ui.sectionTitle
import app.donottype.ui.textButton
import app.donottype.ui.themeColor
import app.donottype.ui.tonalButton
import com.google.android.material.textfield.TextInputEditText
import kotlinx.coroutines.launch

/**
 * Everything that has been dictated, searchable.
 *
 * Its own screen rather than a section near the bottom of settings, because it is not a setting: it
 * is the record of what the app did, and it is where a failed dictation is retried and where the
 * words that never reached a field are recovered from. Settings keeps the two questions that really
 * are settings — how long to keep this, and whether to keep the audio with it.
 */
class HistoryActivity : AppCompatActivity() {

    private lateinit var searchField: TextInputEditText
    private lateinit var summary: TextView
    private lateinit var retryButton: View
    private lateinit var listCard: View
    private lateinit var rows: LinearLayout
    private lateinit var emptyNote: TextView
    private lateinit var deleteSection: LinearLayout

    private val service by lazy { DictationService(this) }
    private var query = HistoryQuery()

    /**
     * The row whose recording the document picker was opened for.
     *
     * The id rather than the record or its bytes: the picker is a trip through another app, and a
     * megabyte of audio held across it is a megabyte held for as long as the user browses. The
     * store is re-read when the answer comes back, which is also what makes a row deleted in the
     * meantime say so instead of writing a file from a stale copy.
     */
    private var pendingAudioRecordId: String? = null

    private val saveAudio = registerForActivityResult(
        ActivityResultContracts.CreateDocument("audio/wav"),
    ) { uri ->
        val id = pendingAudioRecordId
        pendingAudioRecordId = null
        if (uri == null || id == null) return@registerForActivityResult

        val wav = service.history.all().firstOrNull { it.id == id }
            ?.let { service.history.audioFor(it) }
        if (wav == null) {
            summary.text = "The recording for this dictation is no longer on disk."
            return@registerForActivityResult
        }
        runCatching {
            contentResolver.openOutputStream(uri, "wt")?.use { it.write(wav) }
                ?: error("Could not open that file for writing.")
        }.onSuccess {
            Toast.makeText(this, "Recording saved.", Toast.LENGTH_SHORT).show()
        }.onFailure {
            // Uncut: the reason is what tells someone to pick a different folder.
            summary.text = it.message ?: "Could not save the recording."
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Settings.initialise(this)
        title = "History"
        setContentView(buildLayout())
        refresh()
    }

    override fun onResume() {
        super.onResume()
        // A dictation made from the screen behind this one, or by the keyboard, lands here.
        refresh()
    }

    private fun buildLayout(): ScrollView = screenScaffold { column ->
        column.addView(screenTitle("History"))
        column.addView(
            screenSubtitle(
                "Every dictation this device has made. Search it, retry what failed, and see the " +
                    "screen text that was sent with each one.",
            ),
        )

        // Search first, because searching is the reason history is kept at all.
        searchField = TextInputEditText(this).apply {
            contentDescription = "history-search"
            addTextChangedListener(object : TextWatcher {
                override fun afterTextChanged(s: Editable?) {
                    query = query.copy(text = s?.toString().orEmpty())
                    refresh()
                }
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
            })
        }
        column.addView(
            card(
                controlRow(null, fieldContainer("Transcripts, errors, apps", searchField)),
                controlRow("Show", statusFilter()),
            ),
        )

        summary = caption("")
        column.addView(summary)

        // Only when there is something to retry: a button that can do nothing is a button that
        // teaches the user their failures are not fixable.
        retryButton = tonalButton("Retry everything that failed") { retryAll() }
        column.addView(retryButton)

        rows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        listCard = cardHolding(rows)
        column.addView(listCard)

        // Shown instead of an empty card, so "nothing yet" and "nothing matches" read as two
        // different answers rather than as the same blank box.
        emptyNote = sectionFooter("")
        column.addView(emptyNote)

        // Absent rather than disabled while there is nothing to delete: an empty history should
        // not open with the destructive control as its most prominent offer.
        deleteSection = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(sectionTitle("Delete"))
            addView(
                textButton("Delete all history") {
                    service.history.deleteAll()
                    refresh()
                },
            )
            addView(
                sectionFooter(
                    "Removes every transcript and every recording kept with them. How long " +
                        "history is kept without deleting it by hand is in Settings.",
                ),
            )
        }
        column.addView(deleteSection)
    }

    private fun statusFilter(): Spinner {
        val filters = HistoryQuery.StatusFilter.entries
        return Spinner(this).apply {
            adapter = ArrayAdapter(
                this@HistoryActivity,
                android.R.layout.simple_spinner_dropdown_item,
                filters.map { it.label },
            )
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) {
                    query = query.copy(status = filters[pos])
                    refresh()
                }
                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }
    }

    private fun retryAll() {
        lifecycleScope.launch {
            summary.text = "Retrying…"
            val (succeeded, failed) = service.retryAll()
            refresh()
            summary.text = "$succeeded succeeded, $failed still failing"
        }
    }

    private fun refresh() {
        service.history.configure(Settings.retention, Settings.keepAudio)
        val all = service.history.all()
        val records = query.apply(all)
        val retryable = all.count { it.canRetry }

        summary.text = buildString {
            if (records.size == all.size) {
                append("${all.size} dictation${if (all.size == 1) "" else "s"}")
            } else {
                append("${records.size} of ${all.size}")
            }
            if (retryable > 0) append(" · $retryable to retry")
            append(" · ")
            append(Formatter.formatShortFileSize(this@HistoryActivity, service.history.audioBytes()))

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
        retryButton.visibility = if (retryable > 0) View.VISIBLE else View.GONE

        // Rendered in full rather than truncated. A list capped at 20 with nothing said about it
        // reads as "this is your whole history" when it is not; the retention policy is what is
        // supposed to bound how much there is, not the view.
        rows.removeAllViews()
        records.forEachIndexed { index, record ->
            if (index > 0) rows.addView(divider())
            rows.addView(row(record))
        }
        listCard.visibility = if (records.isEmpty()) View.GONE else View.VISIBLE
        emptyNote.text = when {
            records.isNotEmpty() -> ""
            all.isEmpty() -> "No dictations yet. Transcripts appear here, and failed ones can be " +
                "retried from here."
            else -> "Nothing in your history matches that."
        }
        emptyNote.visibility = if (emptyNote.text.isEmpty()) View.GONE else View.VISIBLE
        deleteSection.visibility = if (all.isEmpty()) View.GONE else View.VISIBLE
    }

    private fun row(record: DictationRecord): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            val padding = resources.getDimensionPixelSize(R.dimen.space_m)
            setPadding(
                padding,
                resources.getDimensionPixelSize(R.dimen.space_s),
                padding,
                resources.getDimensionPixelSize(R.dimen.space_s),
            )
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
                    TextView(this@HistoryActivity).apply {
                        text = "$marker  ${record.summary}"
                        textSize = 14f
                        // A long transcript is clamped, because the row is an index and the whole
                        // thing is one tap away in "What was sent". A failure is not clamped: its
                        // message is the thing the user has to read and act on, and it is written
                        // to be copied into a bug report exactly as it appears.
                        if (record.status == DictationRecord.Status.COMPLETED) {
                            maxLines = 3
                            ellipsize = android.text.TextUtils.TruncateAt.END
                        }
                        // Theme attributes rather than hex literals: under a DayNight theme a
                        // fixed dark grey is unreadable at night, which is what these rows looked
                        // like on a dark phone.
                        setTextColor(
                            if (record.status == DictationRecord.Status.COMPLETED) {
                                themeColor(com.google.android.material.R.attr.colorOnSurface)
                            } else {
                                themeColor(androidx.appcompat.R.attr.colorError)
                            },
                        )
                    },
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
                        TextView(this@HistoryActivity).apply {
                            text = details.joinToString(" · ")
                            textSize = 12f
                            // Amber marks a wait long enough to have been noticed. A named colour
                            // with a night variant, not a hex literal, for the reason above.
                            setTextColor(
                                if ((record.latencyMillis ?: 0) > 8_000) {
                                    ContextCompat.getColor(context, R.color.dnt_warning)
                                } else {
                                    themeColor(
                                        com.google.android.material.R.attr.colorOnSurfaceVariant,
                                    )
                                },
                            )
                        },
                    )
                }
            },
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
                            refresh()
                        }
                    }
                },
            )
        } else if (record.status == DictationRecord.Status.COMPLETED) {
            // The transcript went somewhere once; this is how it goes somewhere a second time.
            row.addView(
                textButton("Copy") {
                    val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    clipboard.setPrimaryClip(
                        ClipData.newPlainText("DoNotType transcript", record.deliveredText),
                    )
                    Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show()
                }.apply { layoutParams = wrapContent() },
            )
        }

        // Per-item delete: removing one transcript should not require removing all of them.
        row.addView(
            textButton("✕") {
                service.history.delete(record.id)
                refresh()
            }.apply {
                layoutParams = wrapContent()
                contentDescription = "Delete this transcript"
            },
        )

        // Nothing more to offer unless the recording is still here, which for a dictation that
        // succeeded means the keep-audio setting was on when it was made — so on most rows this
        // second line does not exist at all rather than sitting there disabled.
        if (!record.canRedo) return row

        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(row)
            addView(audioActions(record))
        }
    }

    /**
     * What the kept recording makes possible, under the row it belongs to.
     *
     * A line of its own rather than more buttons beside the transcript: four actions on one line
     * leave the transcript a column too narrow to read, which is the thing the row is for.
     */
    private fun audioActions(record: DictationRecord): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        val padding = resources.getDimensionPixelSize(R.dimen.space_m)
        setPadding(padding, 0, padding, resources.getDimensionPixelSize(R.dimen.space_s))

        // Only where Retry is not already the same button. On a failed row the words never
        // arrived and Retry above transcribes the very same recording; offering "redo" beside it
        // would be two names for one action.
        if (record.status == DictationRecord.Status.COMPLETED) {
            addView(
                textButton("Redo transcription") {}.apply {
                    layoutParams = shareWidth()
                    setOnClickListener {
                        isEnabled = false
                        summary.text = "Transcribing again…"
                        lifecycleScope.launch {
                            service.retry(record)
                            refresh()
                        }
                    }
                },
            )
        }

        // The recording is the evidence behind the row: what a wrong transcript should be judged
        // against, and the one thing here that cannot be reconstructed. A copy — the history keeps
        // its own file, so saving it does not cost the ability to redo it.
        addView(
            textButton("Save audio") {
                pendingAudioRecordId = record.id
                saveAudio.launch(record.audioExportName)
            }.apply { layoutParams = shareWidth() },
        )
    }

    /** Even shares of the row, so a long label ellipsizes rather than pushing the next one off. */
    private fun shareWidth() = LinearLayout.LayoutParams(
        0,
        ViewGroup.LayoutParams.WRAP_CONTENT,
        1f,
    )

    private fun wrapContent() = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
    )
}
