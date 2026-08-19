package app.donottype

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.graphics.Typeface
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import app.donottype.ui.body
import app.donottype.ui.card
import app.donottype.ui.controlRow
import app.donottype.ui.fieldContainer
import app.donottype.ui.primaryButton
import app.donottype.ui.screenScaffold
import app.donottype.ui.screenSubtitle
import app.donottype.ui.screenTitle
import app.donottype.ui.sectionFooter
import app.donottype.ui.sectionTitle
import app.donottype.ui.settingRow
import app.donottype.ui.themeColor
import com.google.android.material.textfield.TextInputEditText
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.EncodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.journeyapps.barcodescanner.BarcodeEncoder
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import java.io.ByteArrayOutputStream

/** File, paste and QR settings transfer. Imported material is always staged in the editor first. */
class SettingsTransferActivity : AppCompatActivity() {
    private lateinit var editor: TextInputEditText
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

    private val openQRImage = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@registerForActivityResult
        runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            require(bounds.outWidth in 1..MAXIMUM_IMAGE_SIDE && bounds.outHeight in 1..MAXIMUM_IMAGE_SIDE) {
                "Choose a QR image no larger than ${MAXIMUM_IMAGE_SIDE} × ${MAXIMUM_IMAGE_SIDE}."
            }

            val bitmap = contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
                ?: error("Could not read that image.")
            val width = bitmap.width
            val height = bitmap.height
            val pixels = IntArray(width * height)
            bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
            bitmap.recycle()
            val source = RGBLuminanceSource(width, height, pixels)
            val value = MultiFormatReader().decode(
                BinaryBitmap(HybridBinarizer(source)),
                mapOf(
                    DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                    DecodeHintType.TRY_HARDER to true,
                ),
            ).text
            SettingsTransfer.parse(SettingsTransfer.decodeQR(value)).root.toString(2)
        }.onSuccess {
            editor.setText(it)
            showStatus("QR image loaded. Review it, then tap Import settings.")
        }.onFailure { showStatus(it.message ?: "No readable settings QR code was found.", true) }
    }

    private val scanCode = registerForActivityResult(ScanContract()) { result ->
        val value = result.contents
        if (value == null) {
            showStatus("Scanning cancelled. No settings were changed.")
            return@registerForActivityResult
        }
        runCatching { SettingsTransfer.parse(SettingsTransfer.decodeQR(value)).root.toString(2) }
            .onSuccess {
                editor.setText(it)
                showStatus("QR code scanned. Review it, then tap Import settings.")
            }
            .onFailure { showStatus(it.message ?: "That QR code is not settings JSON.", true) }
    }

    private val requestCamera = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            openScanner()
        } else {
            showStatus(
                "Camera access is off. Allow it in Android Settings, or import a QR image.", true)
            AlertDialog.Builder(this)
                .setTitle("Camera access is off")
                .setMessage(
                    "Allow camera access in Android Settings to scan a code, or use Import QR " +
                        "image instead.")
                .setPositiveButton("OK", null)
                .show()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Settings.initialise(this)
        title = "Settings transfer"
        setContentView(buildLayout())
        loadCurrent()
        if (intent.getBooleanExtra(EXTRA_START_SCANNER, false)) launchScanner()
    }

    private fun buildLayout(): ScrollView = screenScaffold { column ->
        column.addView(screenTitle("Settings transfer"))
        // Above everything, in the warning colour: every action on this screen moves API keys
        // about in clear text, and that is the part to know before reading how any of it works.
        column.addView(
            body("Exports include API keys in plaintext").apply {
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(
                    ContextCompat.getColor(this@SettingsTransferActivity, R.color.dnt_warning),
                )
            },
        )
        column.addView(
            screenSubtitle(
                "Treat the JSON and QR code like a password. Check the provider and endpoint " +
                    "before importing.",
            ),
        )

        column.addView(sectionTitle("JSON"))
        // Monospace and tall: this is a document to be read and edited, not a value to be typed,
        // and JSON that reflows is JSON nobody can check the shape of.
        editor = TextInputEditText(this).apply {
            minLines = 14
            maxLines = 24
            gravity = Gravity.TOP or Gravity.START
            setTypeface(Typeface.MONOSPACE)
            textSize = 11f
            contentDescription = "settings-json"
        }
        column.addView(card(controlRow(null, fieldContainer("Settings JSON", editor))))

        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        column.addView(
            card(
                settingRow("Paste", "Replace the editor with the clipboard.") {
                    clipboard.primaryClip?.getItemAt(0)
                        ?.coerceToText(this@SettingsTransferActivity)?.toString()?.let {
                            editor.setText(it)
                            showStatus("Pasted JSON. Review it before importing.")
                        }
                },
                settingRow("Copy", "Put the editor's JSON on the clipboard.") {
                    clipboard.setPrimaryClip(
                        ClipData.newPlainText("DoNotType settings", editor.text),
                    )
                    showStatus("Settings JSON copied.")
                },
            ),
        )

        column.addView(sectionTitle("Export"))
        column.addView(
            card(
                settingRow(
                    "Load current settings",
                    "Fill the editor with what this device is using now.",
                ) { loadCurrent() },
                settingRow(
                    "Save JSON file…",
                    "Write the editor out to a file you choose.",
                ) { createDocument.launch("donottype-settings.json") },
                settingRow(
                    "Show QR code",
                    "Put the editor on screen for another device's camera.",
                ) { showQr() },
            ),
        )

        column.addView(sectionTitle("Import"))
        column.addView(
            card(
                settingRow(
                    "Open JSON file…",
                    "Load a file into the editor for review.",
                ) { openDocument.launch(arrayOf("application/json", "text/plain")) },
                settingRow(
                    "Import QR image…",
                    "Read a code out of a screenshot or a photo.",
                ) { openQRImage.launch(arrayOf("image/*")) },
                settingRow(
                    "Scan QR code…",
                    "Point the camera at a code on another device.",
                ) { launchScanner() },
            ),
        )
        column.addView(
            primaryButton("Import settings") { importSettings() }.also {
                it.contentDescription = "import-settings"
            },
        )
        column.addView(
            sectionFooter(
                "Opening or scanning only loads the JSON. Import is separate because a " +
                    "document can replace credentials and network settings.",
            ),
        )

        status = body("").apply { visibility = View.GONE }
        column.addView(status)
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
            val compact = SettingsTransfer.encodeQR(editor.text.toString())
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

    private fun launchScanner() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestCamera.launch(Manifest.permission.CAMERA)
            return
        }
        openScanner()
    }

    private fun openScanner() {
        scanCode.launch(
            ScanOptions()
                .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                .setPrompt("Scan a DoNotType settings QR code")
                .setBeepEnabled(false)
                .setOrientationLocked(false),
        )
    }

    /** The one place the status line is written, so its colour never lags behind its text. */
    private fun showStatus(message: String, error: Boolean = false) {
        status.text = message
        status.setTextColor(
            themeColor(
                if (error) {
                    android.R.attr.colorError
                } else {
                    com.google.android.material.R.attr.colorOnSurfaceVariant
                },
            ),
        )
        status.visibility = if (message.isEmpty()) View.GONE else View.VISIBLE
    }

    companion object {
        const val EXTRA_START_SCANNER = "app.donottype.extra.START_SETTINGS_SCANNER"
        private const val MAXIMUM_IMAGE_SIDE = 4096
    }
}
