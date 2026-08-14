package app.donottype

import app.donottype.core.LogLevel
import app.donottype.core.LogRouter
import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.ViewGroup
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

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
    private lateinit var filterField: EditText
    private lateinit var contentSwitch: Switch
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

    private fun buildLayout(): ScrollView {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(56, 64, 56, 96)
        }

        column.addView(heading("Logs", 24f))
        column.addView(
            body(
                "Every request, retry and failure. Your transcripts and the screen text sent with " +
                    "them are left out unless you turn that on below.",
            ),
        )

        column.addView(sectionTitle("Record"))
        column.addView(
            Spinner(this).apply {
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
            },
        )

        contentSwitch = Switch(this).apply {
            text = "Include transcripts"
            isChecked = Settings.logContent
            setOnCheckedChangeListener { _, checked ->
                Settings.logContent = checked
                refresh()
            }
        }
        column.addView(contentSwitch)

        contentWarning = body("").apply { setTypeface(null, Typeface.BOLD) }
        column.addView(contentWarning)

        column.addView(sectionTitle("Show"))
        filterField = EditText(this).apply {
            hint = "Filter by message, category or field"
            addTextChangedListener(object : TextWatcher {
                override fun afterTextChanged(s: Editable?) {
                    filter = s?.toString().orEmpty()
                    refresh()
                }
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            })
        }
        column.addView(filterField)

        column.addView(
            Spinner(this).apply {
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
            },
        )

        val actions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        actions.addView(button("Refresh") { refresh() })
        actions.addView(
            button("Share") {
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
        actions.addView(
            button("Clear") {
                LogRouter.clearBuffer()
                refresh()
            },
        )
        column.addView(actions)

        output = TextView(this).apply {
            textSize = 11f
            setTypeface(Typeface.MONOSPACE)
            setTextIsSelectable(true)
            setPadding(0, 16, 0, 16)
        }
        column.addView(output)

        return ScrollView(this).apply {
            addView(
                column,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
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
        contentWarning.text = if (Settings.logContent) {
            "The log now contains what you said. Turn this off before sharing it."
        } else {
            ""
        }
    }

    private fun describe(level: LogLevel) = when (level) {
        LogLevel.TRACE -> "Everything (trace)"
        LogLevel.DEBUG -> "Requests and decisions (debug)"
        LogLevel.INFO -> "Normal (info)"
        LogLevel.WARN -> "Warnings only"
        LogLevel.ERROR -> "Errors only"
        LogLevel.OFF -> "Nothing"
    }

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
        setOnClickListener { onClick() }
    }
}
