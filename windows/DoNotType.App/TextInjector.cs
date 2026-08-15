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
