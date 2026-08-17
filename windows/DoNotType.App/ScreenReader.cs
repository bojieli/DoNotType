using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using DoNotType.Core;

namespace DoNotType.App;

/// <summary>
/// Reads on-screen text for grounding, via UI Automation.
///
/// Windows' answer to the macOS accessibility tree, and the closest of the three: it exposes a
/// focused element, a text pattern with a selection, and a walkable subtree. Unlike macOS there is
/// no permission to request — any process may read another's automation tree — which removes an
/// onboarding step and puts more weight on the blocklist.
/// </summary>
public sealed class ScreenReader
{
    /// <summary>A stable identity and full editable value captured at insertion time.</summary>
    public sealed record EditableSnapshot(
        int ProcessId, string RuntimeId, string Value, int SelectionStart, int SelectionLength);

    private const int VisibleTextChars = 10_000;
    private const int CaretWindowChars = 1_000;
    private const int MaxElements = 1_500;

    /// <summary>
    /// App identity and cursor state only. Cheap enough to run synchronously at hotkey-down,
    /// which matters because it is the last moment the focused element is guaranteed to be the
    /// one being dictated into.
    /// </summary>
    public ScreenContext CaptureIdentity()
    {
        var context = new ScreenContext { WindowTitle = Interop.ForegroundWindowTitle() };
        try
        {
            context.AppName = ForegroundProcessName();

            var focused = AutomationElement.FocusedElement;
            if (focused is not null)
            {
                context.Role = focused.Current.ControlType.ProgrammaticName?.Replace("ControlType.", string.Empty);
                context.IsEditable = focused.Current.ControlType == ControlType.Edit
                    || focused.Current.ControlType == ControlType.Document;
                context.SelectedText = SelectedText(focused);
            }
        }
        catch (Exception e) when (e is ElementNotAvailableException or COMException or InvalidOperationException)
        {
            // A window closing mid-read is ordinary. Partial identity beats no dictation.
        }
        return context;
    }

    /// <summary>
    /// The full walk: visible text, the caret window, and the browser URL.
    ///
    /// Bounded by an element budget as well as a character budget — some web pages expose tens of
    /// thousands of automation elements, and walking all of them would blow the deadline long
    /// before filling the character cap.
    /// </summary>
    public ScreenContext CaptureFull(CancellationToken cancellationToken = default)
    {
        var context = CaptureIdentity();
        try
        {
            var window = AutomationElement.FromHandle(Interop.GetForegroundWindow());
            if (window is null) return context;

            var focused = AutomationElement.FocusedElement;
            if (focused is not null)
            {
                var (before, after) = CaretWindow(focused);
                context.TextBeforeCaret = before;
                context.TextAfterCaret = after;
            }

            context.VisibleText = TokenBudget.ClipKeepingTail(
                CollectText(window, cancellationToken), VisibleTextChars);
            context.BrowserUrl = FindBrowserUrl(window);
        }
        catch (Exception e) when (e is ElementNotAvailableException or COMException or InvalidOperationException)
        {
            // Partial grounding beats none.
        }
        return context;
    }

    /// <summary>
    /// Captures the focused editable field for correction learning. Password controls are never
    /// read, and a control without a reliable selection offset is not observed.
    /// </summary>
    public EditableSnapshot? CaptureFocusedEditable()
    {
        try
        {
            var focused = AutomationElement.FocusedElement;
            if (focused is null || focused.Current.IsPassword) return null;
            if (focused.Current.ControlType != ControlType.Edit
                && focused.Current.ControlType != ControlType.Document) return null;
            if (!focused.TryGetCurrentPattern(TextPattern.Pattern, out var raw)
                || raw is not TextPattern pattern) return null;

            var selections = pattern.GetSelection();
            if (selections.Length == 0) return null;
            var selection = selections[0];
            var whole = pattern.DocumentRange;
            var value = whole.GetText(-1);
            var before = whole.Clone();
            before.MoveEndpointByRange(
                TextPatternRangeEndpoint.End, selection, TextPatternRangeEndpoint.Start);
            var start = before.GetText(-1).Length;
            var length = selection.GetText(-1).Length;
            if (start < 0 || start + length > value.Length) return null;

            return new EditableSnapshot(
                focused.Current.ProcessId,
                string.Join('.', focused.GetRuntimeId()),
                value, start, length);
        }
        catch (Exception e) when (e is ElementNotAvailableException or COMException or InvalidOperationException)
        {
            return null;
        }
    }

    private static string ForegroundProcessName()
    {
        Interop.GetWindowThreadProcessId(Interop.GetForegroundWindow(), out var processId);
        if (processId == 0) return string.Empty;
        try
        {
            using var process = Process.GetProcessById((int)processId);
            return process.ProcessName;
        }
        catch (ArgumentException)
        {
            return string.Empty;
        }
    }

    private static string CollectText(AutomationElement root, CancellationToken cancellationToken)
    {
        var builder = new StringBuilder();
        var visited = 0;
        var stack = new Stack<AutomationElement>();
        stack.Push(root);

        var walker = TreeWalker.ControlViewWalker;

        while (stack.Count > 0 && builder.Length < VisibleTextChars && visited < MaxElements)
        {
            if (cancellationToken.IsCancellationRequested) break;
            var element = stack.Pop();
            visited++;

            try
            {
                if (!element.Current.IsOffscreen)
                {
                    Append(builder, element.Current.Name);
                    if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern)
                        && pattern is ValuePattern value)
                    {
                        Append(builder, value.Current.Value);
                    }
                }

                var child = walker.GetFirstChild(element);
                while (child is not null)
                {
                    stack.Push(child);
                    child = walker.GetNextSibling(child);
                }
            }
            catch (Exception e) when (e is ElementNotAvailableException or COMException)
            {
                // Element vanished mid-walk; skip it.
            }
        }
        return builder.ToString();
    }

    private static void Append(StringBuilder builder, string? text)
    {
        var trimmed = text?.Trim();
        // Single characters are almost always chrome: separators, icon labels, badge counts.
        if (string.IsNullOrEmpty(trimmed) || trimmed.Length <= 1) return;
        if (builder.Length > 0) builder.Append('\n');
        builder.Append(trimmed);
    }

    private static (string?, string?) CaretWindow(AutomationElement element)
    {
        try
        {
            if (!element.TryGetCurrentPattern(TextPattern.Pattern, out var raw)
                || raw is not TextPattern pattern)
            {
                return (null, null);
            }

            var whole = pattern.DocumentRange.GetText(-1);
            var selection = pattern.GetSelection();
            if (selection.Length == 0) return (TokenBudget.ClipKeepingTail(whole, CaretWindowChars), null);

            var selected = selection[0].GetText(-1);
            var caret = whole.IndexOf(selected, StringComparison.Ordinal);
            if (caret < 0) return (TokenBudget.ClipKeepingTail(whole, CaretWindowChars), null);

            return (
                TokenBudget.ClipKeepingTail(whole[..caret], CaretWindowChars),
                TokenBudget.ClipKeepingHead(whole[(caret + selected.Length)..], CaretWindowChars));
        }
        catch (Exception e) when (e is ElementNotAvailableException or COMException or InvalidOperationException)
        {
            return (null, null);
        }
    }

    private static string? SelectedText(AutomationElement element)
    {
        try
        {
            if (element.TryGetCurrentPattern(TextPattern.Pattern, out var raw) && raw is TextPattern pattern)
            {
                var selection = pattern.GetSelection();
                if (selection.Length > 0)
                {
                    var text = selection[0].GetText(-1);
                    return string.IsNullOrWhiteSpace(text) ? null : text;
                }
            }
        }
        catch (Exception e) when (e is ElementNotAvailableException or COMException or InvalidOperationException)
        {
            // No text pattern on this control.
        }
        return null;
    }

    /// <summary>Browsers expose the address bar as an edit control named for the URL.</summary>
    private static string? FindBrowserUrl(AutomationElement window)
    {
        try
        {
            var condition = new AndCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit),
                new PropertyCondition(AutomationElement.IsKeyboardFocusableProperty, true));

            foreach (AutomationElement element in window.FindAll(TreeScope.Descendants, condition))
            {
                var name = element.Current.Name ?? string.Empty;
                if (name.Contains("Address", StringComparison.OrdinalIgnoreCase)
                    || name.Contains("Search or enter", StringComparison.OrdinalIgnoreCase))
                {
                    if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var raw)
                        && raw is ValuePattern value
                        && !string.IsNullOrWhiteSpace(value.Current.Value))
                    {
                        return value.Current.Value;
                    }
                }
            }
        }
        catch (Exception e) when (e is ElementNotAvailableException or COMException or InvalidOperationException)
        {
            // Not a browser, or the tree changed underneath us.
        }
        return null;
    }
}
