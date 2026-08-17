package app.donottype

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import java.io.ByteArrayOutputStream

/** File, paste and QR settings transfer. Imported material is always staged in the editor first. */
class SettingsTransferActivity : AppCompatActivity() {
    private lateinit var editor: EditText
    private lateinit var status: TextView

    private val createDocument = registerForActivityResult(
        ActivityResultContracts.CreateDocument("application/json"),
    ) { uri ->
        if (uri == null) return@registerForActivityResult
        runCatching {
            contentResolver.openOutputStream(uri, "wt")?.use {
                it.write(editor.text.toString().toByteArray(Charsets.UTF_8))
            } ?: error("Could not open that file for writing.")
        }.onSuccess { showStatus("Settings JSON saved.") }
            .onFailure { showStatus(it.message ?: "Could not save the file.", true) }
    }

    private val openDocument = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@registerForActivityResult
        runCatching {
            val value = contentResolver.openInputStream(uri)?.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                    require(output.size() <= SettingsTransfer.MAXIMUM_BYTES) {
                        "The settings document is larger than the 1 MB limit."
                    }
                }
                output.toString(Charsets.UTF_8.name())
            } ?: error("Could not read that file.")
            val parsed = SettingsTransfer.parse(value)
            parsed.root.toString(2)
        }.onSuccess {
            editor.setText(it)
            showStatus("JSON loaded. Review it, then tap Import settings.")
        }.onFailure { showStatus(it.message ?: "Could not open the file.", true) }
    }

    private val scanCode = registerForActivityResult(ScanContract()) { result ->
        val value = result.contents ?: return@registerForActivityResult
        runCatching { SettingsTransfer.parse(value).root.toString(2) }
            .onSuccess {
                editor.setText(it)
                showStatus("QR code scanned. Review it, then tap Import settings.")
            }
            .onFailure { showStatus(it.message ?: "That QR code is not settings JSON.", true) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Settings.initialise(this)
        title = "Settings transfer"
        setContentView(buildLayout())
        loadCurrent()
    }

    private fun buildLayout(): ScrollView {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 24, 32, 48)
        }
        column.addView(TextView(this).apply {
            text = "Settings transfer"
            textSize = 24f
            setTypeface(typeface, Typeface.BOLD)
        })
        column.addView(TextView(this).apply {
            text = "⚠ Exports include API keys in plaintext. Treat the JSON and QR code like a " +
                "password. Check the provider and endpoint before importing."
            textSize = 15f
            setPadding(0, 12, 0, 16)
        })

        editor = EditText(this).apply {
            minLines = 14
            maxLines = 24
            gravity = Gravity.TOP or Gravity.START
            setTypeface(Typeface.MONOSPACE)
            textSize = 11f
            contentDescription = "settings-json"
        }
        column.addView(editor)

        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        column.addView(row(
            button("Paste") {
                clipboard.primaryClip?.getItemAt(0)?.coerceToText(this)?.toString()?.let {
                    editor.setText(it)
                    showStatus("Pasted JSON. Review it before importing.")
                }
            },
            button("Copy") {
                clipboard.setPrimaryClip(ClipData.newPlainText("DoNotType settings", editor.text))
                showStatus("Settings JSON copied.")
            },
        ))
        column.addView(row(
            button("Load current") { loadCurrent() },
            button("Save JSON…") { createDocument.launch("donottype-settings.json") },
            button("Show QR") { showQr() },
        ))
        column.addView(row(
            button("Open JSON…") { openDocument.launch(arrayOf("application/json", "text/plain")) },
            button("Scan QR…") {
                scanCode.launch(
                    ScanOptions()
                        .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                        .setPrompt("Scan a DoNotType settings QR code")
                        .setBeepEnabled(false)
                        .setOrientationLocked(false),
                )
            },
        ))
        column.addView(button("Import settings") { importSettings() }.also {
            it.contentDescription = "import-settings"
        })
        column.addView(TextView(this).apply {
            text = "Opening or scanning only loads the JSON. Import is separate because a " +
                "document can replace credentials and network settings."
            textSize = 13f
            setPadding(0, 8, 0, 8)
        })
        status = TextView(this).apply { setPadding(0, 8, 0, 8) }
        column.addView(status)

        return ScrollView(this).apply {
            addView(column)
            ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
                val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                insets
            }
        }
    }

    private fun loadCurrent() {
        runCatching { SettingsTransfer.export() }
            .onSuccess {
                editor.setText(it)
                showStatus("Loaded the current settings.")
            }
            .onFailure { showStatus(it.message ?: "Could not export settings.", true) }
    }

    private fun importSettings() {
        runCatching { SettingsTransfer.parseAndApply(editor.text.toString()) }
            .onSuccess {
                setResult(RESULT_OK)
                editor.setText(SettingsTransfer.export())
                showStatus("Settings imported. API keys were stored with Android Keystore.")
            }
            .onFailure { showStatus(it.message ?: "Could not import settings.", true) }
    }

    private fun showQr() {
        runCatching {
            val compact = SettingsTransfer.parse(editor.text.toString()).root.toString()
            BarcodeEncoder().encodeBitmap(
                compact,
                BarcodeFormat.QR_CODE,
                900,
                900,
                mapOf(EncodeHintType.CHARACTER_SET to "UTF-8"),
            )
        }.onSuccess { bitmap ->
            val image = ImageView(this).apply {
                setImageBitmap(bitmap)
                adjustViewBounds = true
                setPadding(24, 24, 24, 8)
            }
            AlertDialog.Builder(this)
                .setTitle("Settings QR code")
                .setMessage("This QR code contains API keys. Treat it like a password.")
                .setView(image)
                .setPositiveButton("Done", null)
                .show()
        }.onFailure {
            showStatus(
                "These settings do not fit in one QR code. Save or copy the JSON instead.", true)
        }
    }

    private fun showStatus(message: String, error: Boolean = false) {
        status.text = message
        status.setTextColor(if (error) 0xffb00020.toInt() else currentTextColor())
    }

    private fun currentTextColor(): Int =
        android.util.TypedValue().let { value ->
            theme.resolveAttribute(android.R.attr.textColorPrimary, value, true)
            if (value.resourceId != 0) getColor(value.resourceId) else value.data
        }

    private fun button(label: String, action: () -> Unit) = Button(this).apply {
        text = label
        setOnClickListener { action() }
    }

    private fun row(vararg views: Button) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        views.forEach { view ->
            addView(
                view,
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
            )
        }
    }
}
