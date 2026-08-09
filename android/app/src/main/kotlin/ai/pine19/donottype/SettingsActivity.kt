package ai.pine19.donottype

import ai.pine19.donottype.accessibility.ScreenReaderService
import ai.pine19.donottype.core.Fidelity
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.provider.Settings as AndroidSettings
import android.text.InputType
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * Onboarding and settings.
 *
 * Also the only place the microphone permission can be granted: an `InputMethodService` cannot
 * request a runtime permission itself, so the keyboard sends people here.
 *
 * Built in code rather than XML layouts — this is four controls, and a layout file would be more
 * indirection than the screen is worth.
 */
class SettingsActivity : AppCompatActivity() {

    private lateinit var apiKeyField: EditText
    private lateinit var groundingSwitch: Switch
    private lateinit var statusLabel: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Settings.initialise(this)
        setContentView(buildLayout())
        refreshStatus()
    }

    override fun onResume() {
        super.onResume()
        refreshStatus()
    }

    private fun buildLayout(): ScrollView {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(56, 72, 56, 72)
        }

        column.addView(heading("DoNotType"))
        column.addView(
            body(
                "Transcribes what you said, not a tidied-up version of it. Grounded in what is " +
                    "on your screen so names and technical terms are spelled the way you see them."
            )
        )

        column.addView(heading("1 · Your API key"))
        column.addView(
            body(
                "Calls go straight to Google with your own key. Nothing routes through a server " +
                    "of ours. Stored in this app's private storage."
            )
        )
        apiKeyField = EditText(this).apply {
            hint = "Gemini API key"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setText(Settings.apiKey.orEmpty())
        }
        column.addView(apiKeyField)
        column.addView(
            button("Save key") {
                Settings.apiKey = apiKeyField.text.toString().trim()
                refreshStatus()
            }
        )

        column.addView(heading("2 · Microphone"))
        column.addView(
            body("The keyboard records only while you hold the talk button.")
        )
        column.addView(
            button("Grant microphone access") {
                ActivityCompat.requestPermissions(
                    this, arrayOf(Manifest.permission.RECORD_AUDIO), 1,
                )
            }
        )

        column.addView(heading("3 · Enable the keyboard"))
        column.addView(
            button("Open keyboard settings") {
                startActivity(Intent(AndroidSettings.ACTION_INPUT_METHOD_SETTINGS))
            }
        )

        column.addView(heading("4 · Screen grounding (optional)"))
        column.addView(
            body(
                "Reads the text on your current screen while you dictate, so the model can spell " +
                    "what it sees. Read only while you speak, never stored. The keyboard works " +
                    "without this — it just cannot spell what is on screen."
            )
        )
        groundingSwitch = Switch(this).apply {
            text = "Send screen context"
            isChecked = Settings.groundingEnabled
            setOnCheckedChangeListener { _, checked -> Settings.groundingEnabled = checked }
        }
        column.addView(groundingSwitch)
        column.addView(
            button("Open accessibility settings") {
                startActivity(Intent(AndroidSettings.ACTION_ACCESSIBILITY_SETTINGS))
            }
        )

        column.addView(heading("Fidelity"))
        column.addView(buildFidelityPicker())

        statusLabel = body("").apply { setTextColor(Color.parseColor("#4E7A63")) }
        column.addView(statusLabel)

        return ScrollView(this).apply { addView(column) }
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

    private fun refreshStatus() {
        if (!::statusLabel.isInitialized) return
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

    private fun heading(text: String) = TextView(this).apply {
        this.text = text
        textSize = 19f
        setPadding(0, 48, 0, 12)
        gravity = Gravity.START
    }

    private fun body(text: String) = TextView(this).apply {
        this.text = text
        textSize = 14f
        setPadding(0, 0, 0, 16)
    }

    private fun button(title: String, onClick: () -> Unit) = Button(this).apply {
        text = title
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        )
        setOnClickListener { onClick() }
    }
}
