using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace DoNotType.App;

/// <summary>
/// The floating pill at the bottom of the screen while recording.
///
/// It must never take focus, because the whole point is that the caret stays in whatever app the
/// user was already typing in. <c>WS_EX_NOACTIVATE</c> plus <see cref="ShowWithoutActivation"/>
/// is what guarantees that; a plain topmost form would steal it.
/// </summary>
public sealed class RecordingOverlay : Form
{
    public enum Phase
    {
        Recording,
        Transcribing,
        Failed,
    }

    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_TRANSPARENT = 0x00000020;

    private static readonly string[] BarWeights = ["0.45", "0.75", "1.0", "0.7", "0.5"];

    private readonly System.Windows.Forms.Timer _animation = new() { Interval = 33 };
    private double _level;
    private double _phaseOffset;
    private Phase _phase = Phase.Recording;
    private string _hint = string.Empty;

    public RecordingOverlay()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Size = new Size(240, 52);
        BackColor = Color.Black;
        // Rounded pill: the region is cheaper and crisper than an alpha-blended layered window.
        DoubleBuffered = true;

        _animation.Tick += (_, _) =>
        {
            _phaseOffset += 0.12;
            Invalidate();
        };
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var parameters = base.CreateParams;
            parameters.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT;
            return parameters;
        }
    }

    public void UpdateLevel(float level) => _level = Math.Clamp(level * 6.0, 0, 1);

    public void Show(Phase phase, string hint)
    {
        _phase = phase;
        _hint = hint;
        PositionAtBottomOfActiveScreen();
        if (!Visible) base.Show();
        _animation.Start();
        Invalidate();
    }

    public void SetPhase(Phase phase, string hint)
    {
        _phase = phase;
        _hint = hint;
        Invalidate();
    }

    public new void Hide()
    {
        _animation.Stop();
        base.Hide();
    }

    /// <summary>Bottom-centre of whichever screen has the cursor, so it follows a multi-monitor setup.</summary>
    private void PositionAtBottomOfActiveScreen()
    {
        var screen = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(
            screen.Left + (screen.Width - Width) / 2,
            screen.Bottom - Height - 64);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Color.Black);

        using var path = RoundedRect(new Rectangle(0, 0, Width - 1, Height - 1), Height / 2);
        using var fill = new SolidBrush(Color.FromArgb(220, 18, 18, 20));
        using var border = new Pen(Color.FromArgb(40, 255, 255, 255));
        g.FillPath(fill, path);
        g.DrawPath(border, path);
        Region = new Region(path);

        using var textBrush = new SolidBrush(Color.FromArgb(200, 235, 235, 235));
        using var font = new Font(SystemFonts.MessageBoxFont!.FontFamily, 9f, FontStyle.Regular);

        switch (_phase)
        {
            case Phase.Recording:
                DrawWaveform(g, new Rectangle(20, Height / 2 - 11, 76, 22));
                g.DrawString(_hint, font, textBrush, 108, Height / 2 - 8);
                break;
            case Phase.Transcribing:
                // The hint carries "part 2 of 5" for a split dictation, and is empty otherwise.
                var label = _hint.Length == 0 ? "Transcribing…" : $"Transcribing… {_hint}";
                g.DrawString(label, font, textBrush, 24, Height / 2 - 8);
                break;
            default:
                using (var warn = new SolidBrush(Color.FromArgb(230, 240, 160, 90)))
                {
                    g.DrawString(_hint, font, warn, 24, Height / 2 - 8);
                }
                break;
        }
    }

    /// <summary>
    /// Level-driven bars. Deliberately not a spectrum — this is a liveness indicator, and what
    /// people need from it is "the mic is hearing me", which amplitude answers.
    /// </summary>
    private void DrawWaveform(Graphics g, Rectangle bounds)
    {
        using var brush = new SolidBrush(Color.FromArgb(230, 245, 245, 245));
        var barWidth = 4;
        var gap = 5;

        for (var i = 0; i < BarWeights.Length; i++)
        {
            var weight = double.Parse(BarWeights[i]);
            // A slow travelling wave keeps it alive during pauses without implying signal.
            var travel = (Math.Sin(_phaseOffset * 4 + i * 0.9) * 0.5) + 0.5;
            var amplitude = Math.Max(0.12, _level) * weight;
            var height = (int)(4 + (bounds.Height - 4) * Math.Min(1, amplitude * (0.65 + 0.35 * travel)));

            var x = bounds.Left + i * (barWidth + gap);
            var y = bounds.Top + (bounds.Height - height) / 2;
            using var bar = RoundedRect(new Rectangle(x, y, barWidth, height), barWidth / 2);
            g.FillPath(brush, bar);
        }
    }

    private static GraphicsPath RoundedRect(Rectangle bounds, int radius)
    {
        var path = new GraphicsPath();
        var diameter = Math.Max(1, radius * 2);
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _animation.Dispose();
        base.Dispose(disposing);
    }
}
