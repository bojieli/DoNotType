using System.Diagnostics;
using System.Reflection;

namespace DoNotType.App;

/// <summary>
/// What build this is, where it came from, and the licenses it ships under.
/// </summary>
/// <remarks>
/// Exists for the bug report: version, commit and build time are read back from assembly
/// metadata rather than repeated here as literals, so the answer stays right without a
/// release note to keep in sync — and a dev build, which has no meaningful version, still
/// names its commit.
/// </remarks>
internal sealed class AboutTab
{
    private const string RepositoryUrl = "https://github.com/bojieli/DoNotType";

    public TabPage Build()
    {
        var page = new TabPage("About");

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            Padding = new Padding(12),
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        layout.Controls.Add(new Label
        {
            Text = "DoNotType",
            AutoSize = true,
            Font = new Font(SystemFonts.MessageBoxFont!, FontStyle.Bold),
        }, 0, 0);

        layout.Controls.Add(new Label
        {
            Text = $"Version {Version()}",
            AutoSize = true,
        }, 0, 1);
        layout.Controls.Add(new Label
        {
            Text = $"Commit {Metadata("BuildCommit")} · built {Metadata("BuildTimestamp")}",
            AutoSize = true,
        }, 0, 2);

        var link = new LinkLabel { Text = "github.com/bojieli/DoNotType", AutoSize = true };
        link.LinkClicked += (_, _) => Process.Start(new ProcessStartInfo
        {
            FileName = RepositoryUrl,
            UseShellExecute = true,
        });
        layout.Controls.Add(link, 0, 3);

        layout.Controls.Add(new TextBox
        {
            Dock = DockStyle.Fill,
            Multiline = true,
            ReadOnly = true,
            ScrollBars = ScrollBars.Vertical,
            WordWrap = true,
            Text = LicenseText(),
        }, 0, 4);

        for (var row = 0; row < 4; row++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        page.Controls.Add(layout);
        return page;
    }

    /// <summary>
    /// The release version, or "dev" for a build that never got one.
    /// </summary>
    /// <remarks>
    /// AssemblyInformationalVersion is set only when -p:Version is passed (release builds); the
    /// "+…" suffix some SDKs append for the source revision is dropped because the commit is
    /// shown on its own line. Application.ProductVersion reads the same attribute, so it is the
    /// fallback before the literal.
    /// </remarks>
    private static string Version()
    {
        var informational = Assembly.GetEntryAssembly()?
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (informational is { Length: > 0 } value)
            return value.Split('+')[0];
        return Application.ProductVersion is { Length: > 0 } product ? product : "dev";
    }

    private static string Metadata(string key) =>
        Assembly.GetEntryAssembly()?
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(attribute => attribute.Key == key)?.Value
        is { Length: > 0 } value ? value : "dev";

    /// <summary>
    /// The license files shipped next to the executable, concatenated; either may be absent in a
    /// dev layout, and an About tab that fails over a missing file would be its own bug report.
    /// </summary>
    private static string LicenseText()
    {
        var parts = new List<string>();
        foreach (var name in new[] { "LICENSE.txt", "THIRD-PARTY-NOTICES.txt" })
        {
            try
            {
                var path = Path.Combine(AppContext.BaseDirectory, name);
                if (File.Exists(path))
                    parts.Add(File.ReadAllText(path).Replace("\n", "\r\n"));
            }
            catch (IOException)
            {
            }
        }
        return parts.Count == 0
            ? "License files were not found next to the executable."
            : string.Join("\r\n\r\n", parts);
    }
}
