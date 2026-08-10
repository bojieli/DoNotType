using System.Text.Json;
using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// Checks this port of <see cref="ContextEncoder"/> against the Swift reference output.
/// </summary>
/// <remarks>
/// <c>ContextEncoder</c> exists four times, and drift between the ports would be silent: grounding
/// would simply behave slightly differently here, and the near-miss numbers measured on macOS would
/// stop describing what a Windows user gets. Nothing else in the project would notice.
///
/// The fixtures and expected output are the same files the Swift and Kotlin suites read
/// (<c>eval/conformance/</c>), not a copy -- three copies of a contract drift apart on their own.
/// Regenerate deliberately with <c>swift run dnt-eval conformance --write</c>.
/// </remarks>
public class ConformanceTests
{
    private static string? ConformanceDirectory()
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        for (var depth = 0; depth < 10 && directory is not null; depth++)
        {
            var candidate = Path.Combine(directory.FullName, "eval", "conformance", "contexts.json");
            if (File.Exists(candidate))
            {
                return Path.GetDirectoryName(candidate);
            }
            directory = directory.Parent;
        }
        return null;
    }

    private static string? StringOrNull(JsonElement element, string key) =>
        element.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String
            && value.GetString()!.Length > 0
                ? value.GetString()
                : null;

    private static ScreenContext ToContext(JsonElement fixture)
    {
        string? visible = StringOrNull(fixture, "visibleText");
        if (fixture.TryGetProperty("visibleTextRepeat", out var repeat))
        {
            var line = repeat.GetProperty("line").GetString()!;
            var count = repeat.GetProperty("count").GetInt32();
            visible = string.Concat(
                Enumerable.Range(1, count).Select(i => line.Replace("%d", i.ToString())));
        }

        bool? editable = fixture.TryGetProperty("isEditable", out var flag)
            && flag.ValueKind is JsonValueKind.True or JsonValueKind.False
                ? flag.GetBoolean()
                : null;

        return new ScreenContext
        {
            AppName = StringOrNull(fixture, "appName"),
            WindowTitle = StringOrNull(fixture, "windowTitle"),
            BrowserUrl = StringOrNull(fixture, "browserUrl"),
            Role = StringOrNull(fixture, "role"),
            IsEditable = editable,
            VisibleText = visible,
            TextBeforeCaret = StringOrNull(fixture, "textBeforeCaret"),
            TextAfterCaret = StringOrNull(fixture, "textAfterCaret"),
            SelectedText = StringOrNull(fixture, "selectedText"),
            ScreenshotPng = StringOrNull(fixture, "screenshotBase64") is { } base64
                ? Convert.FromBase64String(base64)
                : null,
        };
    }

    private static (JsonElement Cases, JsonElement Golden)? Load()
    {
        var directory = ConformanceDirectory();
        if (directory is null)
        {
            return null;
        }
        return (
            JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "contexts.json"))).RootElement,
            JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "golden.json"))).RootElement);
    }

    [Fact]
    public void EncoderMatchesTheSwiftReferenceOutput()
    {
        if (Load() is not { } loaded)
        {
            return; // eval/ is not reachable from this working directory
        }

        var cases = loaded.Cases.EnumerateArray().ToList();
        var golden = loaded.Golden.EnumerateArray().ToList();
        Assert.Equal(cases.Count, golden.Count);

        for (var index = 0; index < cases.Count; index++)
        {
            var fixture = cases[index];
            var expected = golden[index];
            var id = expected.GetProperty("id").GetString();
            Assert.Equal(fixture.GetProperty("id").GetString(), id);

            var produced = new ContextEncoder().Encode(ToContext(fixture));
            var expectedParts = expected.GetProperty("parts").EnumerateArray().ToList();
            var hint =
                $"{id}: {expected.GetProperty("why").GetString()}\n"
                + "If this change was intended, regenerate with "
                + "`swift run dnt-eval conformance --write` and re-run every port's suite.";

            Assert.True(
                expectedParts.Count == produced.Count,
                $"{hint}\nexpected {expectedParts.Count} parts, got {produced.Count}");

            for (var partIndex = 0; partIndex < produced.Count; partIndex++)
            {
                var want = expectedParts[partIndex];
                switch (produced[partIndex])
                {
                    case InputPart.Text text:
                        Assert.Equal("text", want.GetProperty("type").GetString());
                        Assert.True(
                            want.GetProperty("text").GetString() == text.Value,
                            $"{hint}\npart {partIndex} text differs");
                        break;
                    case InputPart.Image image:
                        Assert.Equal("image", want.GetProperty("type").GetString());
                        Assert.Equal(want.GetProperty("mimeType").GetString(), image.MimeType);
                        Assert.Equal(want.GetProperty("bytes").GetInt32(), image.Data.Length);
                        break;
                    default:
                        Assert.Fail($"{hint}\nunexpected part type at {partIndex}");
                        break;
                }
            }
        }
    }

    /// <summary>
    /// The rules a port is most likely to get wrong, read off the golden file so this doubles as a
    /// specification rather than restating the implementation.
    /// </summary>
    [Fact]
    public void PortFollowsTheRulesTheGoldenFileEncodes()
    {
        if (Load() is not { } loaded)
        {
            return;
        }

        IReadOnlyList<InputPart> Encode(string id)
        {
            foreach (var fixture in loaded.Cases.EnumerateArray())
            {
                if (fixture.GetProperty("id").GetString() == id)
                {
                    return new ContextEncoder().Encode(ToContext(fixture));
                }
            }
            throw new InvalidOperationException($"no fixture {id}");
        }
        static string Text(InputPart part) => ((InputPart.Text)part).Value;

        // Nothing worth sending produces no parts at all, not an empty header.
        Assert.Empty(Encode("12-empty"));

        // Thin accessibility text is dropped without a screenshot and kept with one.
        Assert.DoesNotContain("VISIBLE TEXT", Text(Encode("05-thin-text-no-screenshot")[1]));
        var withShot = Encode("06-thin-text-with-screenshot");
        Assert.IsType<InputPart.Image>(withShot[1]); // the image sits between the two text parts
        Assert.Contains("VISIBLE TEXT", Text(withShot[2]));

        // Clipping keeps the tail: the end of a buffer is the part nearest the caret.
        var longText = Text(Encode("11-long-visible-text")[1]);
        Assert.Contains("line 400:", longText);
        Assert.DoesNotContain("line 1:", longText);

        // Whitespace is not content.
        var blank = Encode("10-whitespace-only-fields");
        Assert.DoesNotContain("URL:", Text(blank[0]));
        Assert.DoesNotContain("SELECTED TEXT", Text(blank[1]));
    }
}
