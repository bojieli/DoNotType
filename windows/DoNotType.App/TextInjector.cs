using DoNotType.Core;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace DoNotType.App;

/// <summary>
/// Puts the transcript into whatever the user was typing in.
///
/// Clipboard save → Ctrl+V → restore. <c>SendInput</c> with per-character key events is the
/// alternative and behaves badly with anything non-ASCII, IME composition, or an app that
/// throttles input. The clipboard is borrowed, not taken: its contents are archived first and put
/// back afterwards.
/// </summary>
public static class TextInjector
{
    /// <summary>
    /// How long to let the target app read the clipboard before restoring it. Restoring too
    /// eagerly races the paste and inserts the user's old clipboard instead of the transcript.
    /// </summary>
    private static readonly TimeSpan RestoreDelay = TimeSpan.FromMilliseconds(250);

    public static async Task InsertAsync(string text, string dictation = "-")
    {
        if (string.IsNullOrEmpty(text)) return;

        // Logged because "it transcribed but nothing appeared" is a distinct failure from "it did
        // not transcribe", and from the outside they look the same. The window that receives the
        // keystrokes is the fact that separates them: a UAC-elevated window silently discards
        // input from an unelevated sender, and nothing anywhere reports that.
        var target = Interop.ForegroundWindowTitle();
        Log.Info(() => "inserting", new Dictionary<string, string>
        {
            ["dictation"] = dictation,
            ["chars"] = text.Length.ToString(),
            ["window"] = target.Length == 0 ? "untitled" : target,
        });

        var archive = SaveClipboard();
        SetClipboardText(text);

        SendPaste();
        await Task.Delay(RestoreDelay).ConfigureAwait(false);

        RestoreClipboard(archive);
        Log.Debug(
            () => "clipboard restored",
            new Dictionary<string, string> { ["dictation"] = dictation });
    }

    /// <summary>Puts the transcript on the clipboard and leaves it there.</summary>
    /// <remarks>
    /// For the cases where the paste must not happen: the words have been recorded, sent and paid
    /// for by then, and the difference between "press Ctrl+V" and "nothing happened" is the
    /// difference between one extra keystroke and an app that looks broken.
    /// </remarks>
    public static void CopyForManualPaste(string text, string dictation = "-")
    {
        if (string.IsNullOrEmpty(text)) return;
        SetClipboardText(text);
        Log.Info(() => "left on the clipboard for a manual paste", new Dictionary<string, string>
        {
            ["dictation"] = dictation,
            ["chars"] = text.Length.ToString(),
        });
    }

    /// <summary>Sends the configured submit keystroke after insertion and focus verification.</summary>
    public static bool Submit(FinishAndSendAction action, string dictation = "-")
    {
        if (action == FinishAndSendAction.Disabled) return false;
        var inputs = action == FinishAndSendAction.ModifiedEnter
            ? new[]
            {
                KeyEvent(Interop.VK_CONTROL, down: true),
                KeyEvent(Interop.VK_RETURN, down: true),
                KeyEvent(Interop.VK_RETURN, down: false),
                KeyEvent(Interop.VK_CONTROL, down: false),
            }
            : new[]
            {
                KeyEvent(Interop.VK_RETURN, down: true),
                KeyEvent(Interop.VK_RETURN, down: false),
            };
        var sent = Interop.SendInput(
            (uint)inputs.Length, inputs, Marshal.SizeOf<Interop.INPUT>()) == (uint)inputs.Length;
        if (sent)
        {
            Log.Info(() => "submission key sent", new Dictionary<string, string>
            {
                ["dictation"] = dictation,
                ["action"] = action.ToString(),
            });
        }
        else
        {
            Log.Warn(
                () => "submission key unavailable",
                new Dictionary<string, string> { ["dictation"] = dictation });
        }
        return sent;
    }

    private static readonly Log Log = new("inject");



    /// <summary>
    /// Every format currently on the clipboard, so a copied image or rich text survives.
    /// </summary>
    private static IDataObject? SaveClipboard()
    {
        try
        {
            var current = Clipboard.GetDataObject();
            if (current is null) return null;

            var copy = new DataObject();
            foreach (var format in current.GetFormats())
            {
                try
                {
                    var data = current.GetData(format);
                    if (data is not null) copy.SetData(format, data);
                }
                catch (ExternalException)
                {
                    // Some formats refuse to be read out of process; skip rather than abort.
                }
            }
            return copy;
        }
        catch (ExternalException)
        {
            // Another process holds the clipboard open. Proceed without an archive rather than
            // failing the dictation.
            return null;
        }
    }

    private static void RestoreClipboard(IDataObject? archive)
    {
        try
        {
            if (archive is null) Clipboard.Clear();
            else Clipboard.SetDataObject(archive, copy: true);
        }
        catch (ExternalException)
        {
            // Losing the previous clipboard is regrettable but not worth an error dialog.
        }
    }

    private static void SetClipboardText(string text)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                Clipboard.SetText(text);
                return;
            }
            catch (ExternalException)
            {
                // The clipboard is a single system-wide resource and is routinely held for a few
                // milliseconds by other apps; retrying is the documented remedy.
                Thread.Sleep(30);
            }
        }
    }

    /// <summary>
    /// Deletes the last <paramref name="count"/> characters with simulated backspaces.
    /// </summary>
    /// <remarks>
    /// By keystroke rather than by setting the field's value: the target window belongs to another
    /// application and most of them expose no settable value, which is the same reason insertion
    /// goes through the clipboard.
    ///
    /// Sent in one batch. A loop of individual SendInput calls interleaves with whatever the user
    /// types next, and the failure mode is deleting characters they typed after the dictation.
    /// </remarks>
    public static void DeleteBackward(int count, string dictation = "-")
    {
        if (count <= 0) return;

        Log.Info(() => "deleting an insertion", new Dictionary<string, string>
        {
            ["dictation"] = dictation,
            ["chars"] = count.ToString(),
            ["window"] = Interop.ForegroundWindowTitle(),
        });

        var inputs = new Interop.INPUT[count * 2];
        for (var index = 0; index < count; index++)
        {
            inputs[index * 2] = KeyEvent(Interop.VK_BACK, down: true);
            inputs[index * 2 + 1] = KeyEvent(Interop.VK_BACK, down: false);
        }
        Interop.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Interop.INPUT>());
    }

    private static void SendPaste()
    {
        var inputs = new[]
        {
            KeyEvent(Interop.VK_CONTROL, down: true),
            KeyEvent(Interop.VK_V, down: true),
            KeyEvent(Interop.VK_V, down: false),
            KeyEvent(Interop.VK_CONTROL, down: false),
        };
        Interop.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Interop.INPUT>());
    }

    private static Interop.INPUT KeyEvent(ushort virtualKey, bool down) => new()
    {
        type = Interop.INPUT_KEYBOARD,
        u = new Interop.InputUnion
        {
            ki = new Interop.KEYBDINPUT
            {
                wVk = virtualKey,
                dwFlags = down ? 0 : Interop.KEYEVENTF_KEYUP,
            },
        },
    };
}
