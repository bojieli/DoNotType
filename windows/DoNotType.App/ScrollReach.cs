using System.Windows.Forms;

namespace DoNotType.App;

/// <summary>
/// Makes the bottom of a scrolling panel reachable.
/// </summary>
internal static class ScrollReach
{
    /// <summary>
    /// Grows the last child's bottom margin by <paramref name="panel"/>'s bottom padding, so
    /// scrolling to the end reaches that child instead of stopping short of it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A scrolling <see cref="FlowLayoutPanel"/> takes its scrollable extent from the last
    /// control's bounds and margin, and the container's own bottom padding is not part of that
    /// extent. Scrolled all the way down, the panel stops with its bottom padding — and whatever
    /// sits in it — still below the fold. Measured on the General tab: neither dropping the
    /// padding nor <see cref="ScrollableControl.AutoScrollMargin"/> moves the extent, and only
    /// the last control's margin does. The slack left at the scroll end tracks that margin minus
    /// the padding, which is why the padding is what gets added here and the control's own margin
    /// is what survives as the visible gap below it.
    /// </para>
    /// <para>
    /// Derived rather than written out, because it is two numbers that have to agree. The General
    /// tab was first fixed with a literal 18 on the Save button matching a literal 18 of padding
    /// on the panel, which is correct only until someone edits one of them. It also spares the
    /// caller from knowing which control is last: in the Context Inspector that depends on
    /// whether the record has a rewritten transcript at all.
    /// </para>
    /// <para>
    /// Call after the last child is added, and before the form declares its
    /// <see cref="ContainerControl.AutoScaleMode"/>. The margin is a 96 DPI number like every
    /// other size in these files, and autoscaling carries it and the padding it compensates for
    /// by the same factor — so the pairing holds at every scale rather than at one of them.
    /// </para>
    /// </remarks>
    internal static void MakeBottomReachable(Panel panel)
    {
        if (panel.Controls.Count == 0) return;

        var last = panel.Controls[^1];
        var margin = last.Margin;
        last.Margin = new Padding(
            margin.Left, margin.Top, margin.Right, margin.Bottom + panel.Padding.Bottom);
    }
}
