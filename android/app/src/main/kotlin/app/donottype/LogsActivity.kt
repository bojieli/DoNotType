package app.donottype

import app.donottype.core.LogLevel
import app.donottype.core.LogRouter
import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import app.donottype.ui.card
import app.donottype.ui.controlRow
import app.donottype.ui.fieldContainer
import app.donottype.ui.monospace
import app.donottype.ui.primaryButton
import app.donottype.ui.screenScaffold
import app.donottype.ui.screenSubtitle
import app.donottype.ui.screenTitle
import app.donottype.ui.sectionFooter
import app.donottype.ui.sectionTitle
import app.donottype.ui.switchRow
import app.donottype.ui.textButton
import app.donottype.ui.tonalButton
import com.google.android.material.textfield.TextInputEditText

/**
 * The log, on the device.
 *
 * This matters more on Android than on a laptop. Logcat needs a cable and a computer, which rules
 * it out for the person who actually has the bug; it is ring-buffered by the system, so the
 * interesting lines are gone by the time anyone looks; and the keyboard is a process nobody is
 * watching a console for when it fails. Without this screen, "it stopped working" has no evidence
 * attached to it at all.
 *
 * Share rather than reveal: on Android the way a log reaches a bug report is a share sheet.
 */
class LogsActivity : AppCompatActivity() {

    private lateinit var output: TextView
    private lateinit var filterField: TextInputEditText
    private lateinit var contentWarning: TextView

    private var minimumLevel = LogLevel.TRACE
    private var filter = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Settings.initialise(this)
        title = "Logs"
        setContentView(buildLayout())
        refresh()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun buildLayout(): ScrollView = screenScaffold { column ->
        column.addView(screenTitle("Logs"))
        column.addView(
            screenSubtitle(
                "Every request, retry and failure. Your transcripts and the screen text sent with " +
                    "them are left out unless you turn that on below.",
            ),
        )

        column.addView(sectionTitle("Record"))
        column.addView(
            card(
                controlRow("Detail", recordLevelSpinner()),
                switchRow(
                    "Include transcripts",
                    "What you said, and the screen text sent with it.",
                    checked = Settings.logContent,
                ) { checked ->
                    Settings.logContent = checked
                    refresh()
                },
            ),
        )
        // Bold and in the warning colour, because it is the one line on this screen that can cost
        // the user something: sharing a log they did not know had their words in it.
        contentWarning = sectionFooter("").apply {
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(ContextCompat.getColor(this@LogsActivity, R.color.dnt_warning))
        }
        column.addView(contentWarning)

        column.addView(sectionTitle("Show"))
        filterField = TextInputEditText(this).apply {
            addTextChangedListener(object : TextWatcher {
                override fun afterTextChanged(s: Editable?) {
                    filter = s?.toString().orEmpty()
                    refresh()
                }
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            })
        }
        column.addView(
            card(
                controlRow(null, fieldContainer("Filter by message, category or field", filterField)),
                controlRow("Minimum level", showLevelSpinner()),
            ),
        )

        // Share is the point of the screen -- a log nobody can send is a log nobody reads.
        column.addView(
            primaryButton("Share") {
                // Already redacted by the router, so this is safe to hand to whatever the user
                // picks -- which is the point of it being redacted at the source.
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_SUBJECT, "DoNotType log")
                    putExtra(Intent.EXTRA_TEXT, output.text.toString())
                }
                startActivity(Intent.createChooser(intent, "Share the log"))
            },
        )
        column.addView(tonalButton("Refresh") { refresh() })
        column.addView(
            textButton("Clear") {
                LogRouter.clearBuffer()
                refresh()
            },
        )

        column.addView(sectionTitle("Recent"))
        output = monospace("")
        column.addView(card(controlRow(null, output)))
    }

    /** How much the router keeps. Changing it takes effect from the next event onwards. */
    private fun recordLevelSpinner(): Spinner = Spinner(this).apply {
        val levels = LogLevel.entries
        adapter = ArrayAdapter(
            this@LogsActivity,
            android.R.layout.simple_spinner_dropdown_item,
            levels.map { describe(it) },
        )
        setSelection(levels.indexOf(Settings.logLevel).coerceAtLeast(0))
        onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(
                parent: AdapterView<*>?,
                view: android.view.View?,
                position: Int,
                id: Long,
            ) {
                Settings.logLevel = levels[position]
                refresh()
            }

            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
    }

    /** How much of what was kept is shown. Purely a view filter; nothing is discarded. */
    private fun showLevelSpinner(): Spinner = Spinner(this).apply {
        val levels = listOf(
            LogLevel.TRACE to "All",
            LogLevel.DEBUG to "Debug and up",
            LogLevel.INFO to "Info and up",
            LogLevel.WARN to "Warnings and up",
            LogLevel.ERROR to "Errors only",
        )
        adapter = ArrayAdapter(
            this@LogsActivity,
            android.R.layout.simple_spinner_dropdown_item,
            levels.map { it.second },
        )
        onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(
                parent: AdapterView<*>?,
                view: android.view.View?,
                position: Int,
                id: Long,
            ) {
                minimumLevel = levels[position].first
                refresh()
            }

            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
    }

    private fun refresh() {
        val events = LogRouter.recent(limit = 500, minimumLevel = minimumLevel, containing = filter)
        output.text = if (events.isEmpty()) {
            "Nothing logged yet. Set Record to Debug to see every request, the backend that " +
                "answered and each retry."
        } else {
            events.joinToString("\n") { it.render() }
        }
        contentWarning.text =
            "The log now contains what you said. Turn this off before sharing it."
        contentWarning.visibility = if (Settings.logContent) TextView.VISIBLE else TextView.GONE
    }

    private fun describe(level: LogLevel) = when (level) {
        LogLevel.TRACE -> "Everything (trace)"
        LogLevel.DEBUG -> "Requests and decisions (debug)"
        LogLevel.INFO -> "Normal (info)"
        LogLevel.WARN -> "Warnings only"
        LogLevel.ERROR -> "Errors only"
        LogLevel.OFF -> "Nothing"
    }
}
