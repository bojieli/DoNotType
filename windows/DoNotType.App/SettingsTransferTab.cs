using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using ZXing;
using ZXing.Common;

namespace DoNotType.App;

/// <summary>JSON file, clipboard and QR-image settings transfer for Windows.</summary>
public sealed class SettingsTransferTab(
    AppSettings settings,
    DictationController controller,
    Action onImported)
{
    private readonly TextBox _editor = new()
    {
        Multiline = true,
        ScrollBars = ScrollBars.Both,
        WordWrap = false,
        Dock = DockStyle.Fill,
        Font = new Font(FontFamily.GenericMonospace, 9f),
        AcceptsReturn = true,
        AcceptsTab = true,
    };

    private readonly Label _status = new()
    {
        AutoSize = false,
        Dock = DockStyle.Fill,
        TextAlign = ContentAlignment.MiddleLeft,
    };

    public TabPage Build()
    {
        var page = new TabPage("Transfer");
        var top = new Panel { Dock = DockStyle.Top, Height = 102, Padding = new Padding(12, 8, 12, 4) };
        var warning = new Label
        {
            Text = "⚠ Exports include API keys in plaintext. Treat the JSON file and QR code "
                + "like a password; review the provider and endpoint before importing.",
            ForeColor = Color.DarkOrange,
            Dock = DockStyle.Top,
            Height = 38,
        };
        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            Height = 42,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
        };

        Button Add(string label, Action action)
        {
            var button = new Button { Text = label, AutoSize = true };
            button.Click += (_, _) => action();
            buttons.Controls.Add(button);
            return button;
        }

        Add("Load current", LoadCurrent);
        Add("Paste", () =>
        {
            if (Clipboard.ContainsText()) _editor.Text = Clipboard.GetText();
            Note("Pasted JSON. Review it before importing.");
        });
        Add("Copy", () =>
        {
            Clipboard.SetText(_editor.Text);
            Note("Settings JSON copied.");
        });
        Add("Save JSON…", SaveFile);
        Add("Show QR", ShowQr);
        Add("Open JSON…", OpenFile);
        Add("Import QR image…", ImportQrImage);

        top.Controls.Add(buttons);
        top.Controls.Add(warning);

        var bottom = new Panel { Dock = DockStyle.Bottom, Height = 72, Padding = new Padding(12, 6, 12, 8) };
        var import = new Button
        {
            Text = "Import settings",
            Width = 130,
            Dock = DockStyle.Left,
        };
        import.Click += (_, _) => Import();
        bottom.Controls.Add(_status);
        bottom.Controls.Add(import);

        page.Controls.Add(_editor);
        page.Controls.Add(bottom);
        page.Controls.Add(top);
        page.Enter += (_, _) => { if (_editor.TextLength == 0) LoadCurrent(); };
        return page;
    }

    private void LoadCurrent()
    {
        Try(() =>
        {
            _editor.Text = SettingsTransfer.Encode(SettingsTransfer.Export(settings));
            Note("Loaded the current settings.");
        });
    }

    private void SaveFile()
    {
        using var dialog = new SaveFileDialog
        {
            Filter = "JSON files (*.json)|*.json|Text files (*.txt)|*.txt",
            FileName = "donottype-settings.json",
            DefaultExt = "json",
        };
        if (dialog.ShowDialog() != DialogResult.OK) return;
        Try(() =>
        {
            File.WriteAllText(dialog.FileName, _editor.Text);
            Note("Settings JSON saved.");
        });
    }

    private void OpenFile()
    {
        using var dialog = new OpenFileDialog
        {
            Filter = "JSON files (*.json)|*.json|Text files (*.txt)|*.txt|All files (*.*)|*.*",
        };
        if (dialog.ShowDialog() != DialogResult.OK) return;
        Try(() =>
        {
            var info = new FileInfo(dialog.FileName);
            if (info.Length > SettingsTransfer.MaximumBytes)
                throw new InvalidDataException("The settings document is larger than the 1 MB limit.");
            var document = SettingsTransfer.Decode(File.ReadAllText(dialog.FileName));
            _editor.Text = SettingsTransfer.Encode(document);
            Note("JSON loaded. Review it, then choose Import settings.");
        });
    }

    private void Import()
    {
        Try(() =>
        {
            var document = SettingsTransfer.Decode(_editor.Text);
            SettingsTransfer.Apply(document, settings);
            controller.ReloadHotkey();
            onImported();
            _editor.Text = SettingsTransfer.Encode(SettingsTransfer.Export(settings));
            Note("Settings imported. API keys were encrypted for this Windows account.");
        });
    }

    private void ShowQr()
    {
        Try(() =>
        {
            var document = SettingsTransfer.Decode(_editor.Text);
            var compact = SettingsTransfer.EncodeQr(document);
            var bitmap = QrImages.Encode(compact, 640);
            var window = new Form
            {
                Text = "Settings QR code",
                Icon = AppIcon.Window,
                ClientSize = new Size(680, 725),
                StartPosition = FormStartPosition.CenterParent,
                MinimizeBox = false,
                MaximizeBox = false,
            };
            var image = new PictureBox
            {
                Image = bitmap,
                SizeMode = PictureBoxSizeMode.Zoom,
                Dock = DockStyle.Fill,
                Padding = new Padding(16),
            };
            var warning = new Label
            {
                Text = "This QR code contains API keys. Treat it like a password.",
                ForeColor = Color.DarkOrange,
                TextAlign = ContentAlignment.MiddleCenter,
                Dock = DockStyle.Bottom,
                Height = 45,
            };
            window.Controls.Add(image);
            window.Controls.Add(warning);
            window.FormClosed += (_, _) => bitmap.Dispose();
            window.ShowDialog();
        });
    }

    private void ImportQrImage()
    {
        using var dialog = new OpenFileDialog
        {
            Filter = "Image files|*.png;*.jpg;*.jpeg;*.bmp;*.gif|All files (*.*)|*.*",
        };
        if (dialog.ShowDialog() != DialogResult.OK) return;
        Try(() =>
        {
            using var image = new Bitmap(dialog.FileName);
            var value = QrImages.Decode(image)
                ?? throw new InvalidDataException("No QR code was found in that image.");
            var document = SettingsTransfer.DecodeQr(value);
            _editor.Text = SettingsTransfer.Encode(document);
            Note("QR image loaded. Review it, then choose Import settings.");
        });
    }

    private void Try(Action action)
    {
        try { action(); }
        catch (Exception error) when (
            error is IOException or UnauthorizedAccessException or ArgumentException
                or ExternalException or OutOfMemoryException)
        {
            Note(error.Message, error: true);
        }
    }

    private void Note(string value, bool error = false)
    {
        _status.Text = value;
        _status.ForeColor = error ? Color.Firebrick : SystemColors.ControlText;
    }

    private static class QrImages
    {
        public static Bitmap Encode(string value, int size)
        {
            BitMatrix matrix;
            try
            {
                matrix = new MultiFormatWriter().encode(
                    value, BarcodeFormat.QR_CODE, size, size,
                    new Dictionary<EncodeHintType, object>
                    {
                        [EncodeHintType.CHARACTER_SET] = "UTF-8",
                        [EncodeHintType.MARGIN] = 4,
                    });
            }
            catch (Exception error)
            {
                throw new InvalidDataException(
                    "These settings do not fit in one QR code. Save or copy the JSON instead.", error);
            }

            var bitmap = new Bitmap(matrix.Width, matrix.Height, PixelFormat.Format32bppArgb);
            var rectangle = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
            var data = bitmap.LockBits(rectangle, ImageLockMode.WriteOnly, bitmap.PixelFormat);
            try
            {
                var pixels = new byte[Math.Abs(data.Stride) * data.Height];
                for (var y = 0; y < matrix.Height; y++)
                {
                    for (var x = 0; x < matrix.Width; x++)
                    {
                        var offset = y * data.Stride + x * 4;
                        var channel = matrix[x, y] ? (byte)0 : (byte)255;
                        pixels[offset] = channel;
                        pixels[offset + 1] = channel;
                        pixels[offset + 2] = channel;
                        pixels[offset + 3] = 255;
                    }
                }
                Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
            }
            finally { bitmap.UnlockBits(data); }
            return bitmap;
        }

        public static string? Decode(Bitmap bitmap)
        {
            if (bitmap.Width > 4_096 || bitmap.Height > 4_096)
                throw new InvalidDataException("The QR image is larger than 4096 × 4096 pixels.");
            var rgb = new byte[bitmap.Width * bitmap.Height * 3];
            for (var y = 0; y < bitmap.Height; y++)
            {
                for (var x = 0; x < bitmap.Width; x++)
                {
                    var color = bitmap.GetPixel(x, y);
                    var offset = (y * bitmap.Width + x) * 3;
                    rgb[offset] = color.R;
                    rgb[offset + 1] = color.G;
                    rgb[offset + 2] = color.B;
                }
            }
            var source = new RGBLuminanceSource(
                rgb, bitmap.Width, bitmap.Height, RGBLuminanceSource.BitmapFormat.RGB24);
            try
            {
                return new MultiFormatReader()
                    .decode(new BinaryBitmap(new HybridBinarizer(source)))?.Text;
            }
            catch (ReaderException) { return null; }
        }
    }
}
