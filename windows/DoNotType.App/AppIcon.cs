using System.Drawing;

namespace DoNotType.App;

/// <summary>
/// The app mark, rendered from the same Resources/Icon/DoNotType.svg that macOS, Android and iOS
/// use, and embedded in the assembly rather than read from disk so a single-file publish carries
/// it with no loose file to lose.
/// </summary>
/// <remarks>
/// The .ico holds every size from 16 to 256, and the two accessors below ask for the one Windows
/// wants: the notification area uses the small metric, which is 16 at 100% DPI and 24 at 150%, and
/// a window's title bar and the task switcher use the large one. Handing the wrong size over and
/// letting Windows scale it is what makes a tray icon look soft.
/// </remarks>
internal static class AppIcon
{
    private const string ResourceName = "DoNotType.ico";

    private static Icon? _small;
    private static Icon? _window;

    /// <summary>For the notification area.</summary>
    internal static Icon Small => _small ??= Load(SystemInformation.SmallIconSize);

    /// <summary>For window title bars, Alt-Tab and the taskbar.</summary>
    internal static Icon Window => _window ??= Load(SystemInformation.IconSize);

    private static Icon Load(Size size)
    {
        // Absent only if someone drops the EmbeddedResource from the csproj, which is a broken
        // build rather than a runtime condition -- so it says so instead of quietly substituting
        // the generic Windows placeholder this app used to ship.
        using var stream = typeof(AppIcon).Assembly.GetManifestResourceStream(ResourceName)
            ?? throw new InvalidOperationException(
                $"{ResourceName} is not embedded in the assembly. Check DoNotType.App.csproj.");
        return new Icon(stream, size);
    }
}
