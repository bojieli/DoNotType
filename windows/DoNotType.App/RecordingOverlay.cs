using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using DoNotType.Core;

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
        /// <summary>
        /// The second request. Distinct from <see cref="Transcribing"/> because it is a different
        /// thing to be waiting on and usually the slower of the two — and because the transcript
        /// exists by then, so nothing on screen is moving and a stale label reads as a hang.
        /// </summary>
        Deriving,
        /// <summary>
        /// Brief confirmation that words were inserted, so success is visible rather than a silent
        /// disappearance the user has to infer from the text appearing.
        /// </summary>
        Inserted,
        Failed,
    }

    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_TRANSPARENT = 0x00000020;

    /// <summary>
    /// How much of the recording the meter shows: 24 bars of 60 ms, so a second and a half. Long
    /// enough that the sentence being spoken is on screen, short enough for the bars to stay
    /// readable.
    /// </summary>
    private const int VisibleBars = 24;
    private const int MeterBarWidth = 3;
    private const int MeterBarGap = 2;
    /// <summary>Sized from the bar count, so the pill's width follows from one number.</summary>
    private const int MeterWidth = (VisibleBars * MeterBarWidth) + ((VisibleBars - 1) * MeterBarGap);

    /// <summary>
    /// The visible history, oldest first. Always full: the meter starts flat rather than growing in
    /// from the left, because an empty meter and a silent one should not look different.
    /// </summary>
    private readonly AudioLevelMeter.Bar[] _bars =
        [.. Enumerable.Repeat(AudioLevelMeter.Bar.Silent, VisibleBars)];

    private readonly System.Windows.Forms.Timer _animation = new() { Interval = 33 };
    /// <summary>Room for the meter and a few words. Everything but a failure fits.</summary>
    private const int CompactWidth = 320;
    private const int CompactHeight = 52;

    /// <summary>
    /// Wider, and as tall as the text needs, for a failure.
    /// </summary>
    /// <remarks>
    /// The message used to be cut to 48 characters by the caller, which is shorter than every
    /// sentence worth reading — "The API key was rejected. Check it in Settings." does not fit, and
    /// what somebody saw was the first half of the diagnosis with the instruction missing.
    /// </remarks>
    private const int FailureWidth = 420;

    private Phase _phase = Phase.Recording;
    private string _hint = string.Empty;

    public RecordingOverlay()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Size = new Size(CompactWidth, CompactHeight);
        BackColor = Color.Black;
        // Rounded pill: the region is cheaper and crisper than an alpha-blended layered window.
        DoubleBuffered = true;

        // Repaints the thinking dots, which are drawn from the clock. The meter does not need it:
        // it repaints when audio arrives, which is the only time it has anything new to say.
        _animation.Tick += (_, _) => Invalidate();
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

    /// <summary>Adds however many bars the microphone has produced since the last redraw.</summary>
    public void AppendLevels(IReadOnlyList<AudioLevelMeter.Bar> bars)
    {
        if (bars.Count == 0) return;

        var incoming = Math.Min(bars.Count, VisibleBars);
        Array.Copy(_bars, incoming, _bars, 0, VisibleBars - incoming);
        for (var index = 0; index < incoming; index++)
        {
            _bars[VisibleBars - incoming + index] = bars[bars.Count - incoming + index];
        }
        Invalidate();
    }

    private void ClearLevels() => Array.Fill(_bars, AudioLevelMeter.Bar.Silent);

    public void Show(Phase phase, string hint)
    {
        _phase = phase;
        _hint = hint;
        ClearLevels();
        ResizeForPhase();
        PositionAtBottomOfActiveScreen();
        if (!Visible) base.Show();
        _animation.Start();
        Invalidate();
    }

    /// <param name="hint">Extra detail under the phase, or null when there is none worth showing.</param>
    public void SetPhase(Phase phase, string? hint)
    {
        _phase = phase;
        _hint = hint ?? string.Empty;
        ResizeForPhase();
        PositionAtBottomOfActiveScreen();
        Invalidate();
    }

    /// <summary>
    /// A failure gets as much room as its sentence needs; everything else stays a pill.
    /// </summary>
    private void ResizeForPhase()
    {
        if (_phase != Phase.Failed)
        {
            Size = new Size(CompactWidth, CompactHeight);
            return;
        }

        using var graphics = CreateGraphics();
        using var font = MessageFont();
        var measured = graphics.MeasureString(
            _hint, font, FailureWidth - TextLeft - 24);
        Size = new Size(FailureWidth, Math.Max(CompactHeight, (int)measured.Height + 28));
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
        using var font = MessageFont();

        switch (_phase)
        {
            case Phase.Recording:
                DrawMeter(g, new Rectangle(20, Height / 2 - 11, MeterWidth, 22));
                g.DrawString(_hint, font, textBrush, TextLeft, Height / 2 - 8);
                break;

            case Phase.Transcribing:
                // Dots rather than a static label alone. After the user stops talking the wait is
                // dead time, and the failure to prevent is them deciding nothing happened and
                // pressing the key again mid-request. Deliberately unlike the recording waveform:
                // there is no input left to reflect, so anything level-driven would be decoration
                // pretending to be a signal.
                DrawThinkingDots(g, new Rectangle(20, Height / 2 - 4, MeterWidth, 8));
                var label = _hint.Length == 0 ? "Transcribing…" : $"Transcribing… {_hint}";
                g.DrawString(label, font, textBrush, TextLeft, Height / 2 - 8);
                break;

            case Phase.Deriving:
                DrawThinkingDots(g, new Rectangle(20, Height / 2 - 4, MeterWidth, 8));
                g.DrawString(
                    _hint.Length == 0 ? "Rewriting…" : _hint, font, textBrush,
                    TextLeft, Height / 2 - 8);
                break;

            case Phase.Inserted:
                DrawTick(g, new Rectangle(24, Height / 2 - 7, 14, 14));
                g.DrawString(_hint, font, textBrush, 48, Height / 2 - 8);
                break;

            default:
                using (var warn = new SolidBrush(Color.FromArgb(230, 240, 160, 90)))
                using (var format = new StringFormat { Trimming = StringTrimming.EllipsisWord })
                {
                    // Wrapped rather than cut. The advice is a sentence about what to do, and half
                    // a sentence about what to do is worse than none.
                    g.DrawString(
                        _hint, font, warn,
                        new RectangleF(24, 14, Width - 48, Height - 24), format);
                }
                break;
        }
    }

    private static Font MessageFont() =>
        new(SystemFonts.MessageBoxFont!.FontFamily, 9f, FontStyle.Regular);

    /// <summary>Where the label starts, clear of the meter or the dots.</summary>
    private const int TextLeft = 20 + MeterWidth + 12;

    /// <summary>A tick, drawn rather than shipped as an icon so it inherits the pill's colours.</summary>
    private static void DrawTick(Graphics g, Rectangle bounds)
    {
        using var pen = new Pen(Color.FromArgb(230, 120, 210, 130), 2.2f)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
        };
        g.DrawLines(pen, [
            new PointF(bounds.Left, bounds.Top + bounds.Height * 0.55f),
            new PointF(bounds.Left + bounds.Width * 0.38f, bounds.Bottom - 1),
            new PointF(bounds.Right, bounds.Top + 1),
        ]);
    }

    /// <summary>Three dots travelling in one direction, so the group reads as motion rather than
    /// as three things blinking independently.</summary>
    private void DrawThinkingDots(Graphics g, Rectangle bounds)
    {
        const int dots = 3;
        var phase = Environment.TickCount / 1000.0;
        var spacing = bounds.Width / (float)(dots + 1);

        for (var index = 0; index < dots; index++)
        {
            var local = Math.Abs(Math.Sin(phase * 3 - index * 0.7));
            var radius = (float)(3 + 2 * local);
            var alpha = (int)Math.Clamp(120 + 135 * local, 0, 255);

            using var brush = new SolidBrush(Color.FromArgb(alpha, 127, 178, 255));
            var centreX = bounds.Left + spacing * (index + 1);
            g.FillEllipse(
                brush, centreX - radius, bounds.Top + bounds.Height / 2f - radius,
                radius * 2, radius * 2);
        }
    }

    /// <summary>
    /// The last second and a half of the microphone, walking leftwards.
    /// </summary>
    /// <remarks>
    /// <para>
    /// What it replaced is worth saying, because it looked like this. The old meter was five bars
    /// driven by a single current level and animated by a travelling sine wave, and neither half
    /// reported anything: the level was <c>peak * 6</c> clamped, which a normally-recorded voice
    /// sat pinned at the top of — see <see cref="AudioLevelMeter"/> for the measurement — and the
    /// movement was invented, so the bars swayed identically whether the microphone was hearing a
    /// sentence or nothing at all.
    /// </para>
    /// <para>
    /// Here every bar is 60 ms of audio that actually happened, and the meter moves because the
    /// audio does. Silence is a flat row of dots that keeps scrolling: the microphone is live and
    /// hearing nothing.
    /// </para>
    /// </remarks>
    private void DrawMeter(Graphics g, Rectangle bounds)
    {
        using var brush = new SolidBrush(Color.FromArgb(230, 245, 245, 245));
        // Amber is not decoration: the input is loud enough to be clipped on the way in, and a
        // recording distorted before it is sent is worth one colour. The same amber as a failure,
        // because it is the same kind of news.
        using var clipped = new SolidBrush(Color.FromArgb(230, 240, 160, 90));

        for (var index = 0; index < _bars.Length; index++)
        {
            var bar = _bars[index];
            // Silence is a row of dots rather than nothing at all: a meter that disappears when the
            // room is quiet cannot be told apart from one that has stopped.
            var height = Math.Max(MeterBarWidth, (int)(bounds.Height * bar.Level));
            var x = bounds.Left + index * (MeterBarWidth + MeterBarGap);
            var y = bounds.Top + (bounds.Height - height) / 2;

            using var shape = RoundedRect(
                new Rectangle(x, y, MeterBarWidth, height), MeterBarWidth / 2);
            g.FillPath(bar.IsClipping ? clipped : brush, shape);
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
