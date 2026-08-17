namespace DoNotType.Core;

/// <summary>
/// The user's own copies of prompt parts, if they have edited any.
///
/// This is open-source software whose entire behaviour is a prompt, so making that prompt readable
/// but not editable would be an odd line to draw. Every part can be edited on its own and restored
/// on its own; the shipped text is always one button away.
///
/// One caveat belongs in any UI that exposes this: the numbers in PROMPT.md's changelog were
/// measured against the shipped parts, and an edited part invalidates them.
/// </summary>
public sealed class PromptStore(string directory)
{
    /// <summary>What a migration from the single-file format did, for the message that reports it.</summary>
    public sealed record Migration(IReadOnlyList<PromptPart> Migrated, string ArchivedAt);

    /// <summary>
    /// Overrides live in prompt/ under the history directory, mirroring the shipped layout so
    /// "which file is in force" is answered by existence alone.
    /// </summary>
    public string PromptDirectory => Path.Combine(directory, "prompt");

    /// <summary>Where the pre-split single file lived.</summary>
    public string LegacyPath => Path.Combine(directory, "PROMPT.md");

    public string PathFor(PromptPart part) => Path.Combine(PromptDirectory, part.RelativePath);

    public bool IsCustom(PromptPart part) => File.Exists(PathFor(part));

    public IReadOnlyList<PromptPart> CustomParts => [.. PromptPart.All.Where(IsCustom)];

    public bool HasCustomPrompt => CustomParts.Count > 0;

    public PromptSource Source(string bundled) => new(bundled, PromptDirectory);

    public PromptBuilder Builder(string bundled) => new(Source(bundled));

    /// <summary>
    /// Validates before writing. A part that cannot build is a silently broken app, and the failure
    /// would surface mid-dictation rather than at the moment of editing.
    /// </summary>
    public void Save(string text, PromptPart part)
    {
        Validate(text, part);
        var destination = PathFor(part);
        AtomicFile.ReplaceText(destination, text.Trim() + "\n");
    }

    public void Restore(PromptPart part)
    {
        if (IsCustom(part)) File.Delete(PathFor(part));
    }

    public void RestoreAll()
    {
        foreach (var part in CustomParts) Restore(part);
    }

    /// <summary>
    /// Checks that a part will build. Much less than the old whole-file validation had to check: a
    /// part the user has not edited cannot be missing, because the shipped one is still there.
    /// </summary>
    public static void Validate(string text, PromptPart part)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            throw new InvalidOperationException(
                $"{part.Id} is empty. A part file is sent in full, so an empty one sends nothing.");
        }
        if (part.Placeholder is { } placeholder && !text.Contains(placeholder))
        {
            throw new InvalidOperationException(
                $"{part.Id} needs a {placeholder} placeholder — without it the clause chosen in "
                + "settings would never reach the model.");
        }
    }

    /// <summary>
    /// Splits a pre-split PROMPT.md override into part files, once.
    /// </summary>
    /// <remarks>
    /// Only parts that actually differ from the shipped text become overrides. A user who edited one
    /// fidelity clause and left everything else alone should end up with one override, not twelve --
    /// twelve would pin the whole contract at the version they happened to copy, which is the failure
    /// mode the split exists to remove.
    ///
    /// Returns null when there is nothing to migrate. Never throws for a malformed old file: an
    /// unparseable prompt means the user gets the shipped one, which is the same thing that would
    /// have happened before.
    /// </remarks>
    public Migration? MigrateLegacyPrompt(string bundled)
    {
        if (!File.Exists(LegacyPath)) return null;

        var legacy = new LegacyPromptFile(File.ReadAllText(LegacyPath));
        if (!legacy.IsLegacyFormat) return null;

        var shipped = new PromptSource(bundled);
        var found = legacy.Parts();
        var migrated = new List<PromptPart>();
        foreach (var part in PromptPart.All)
        {
            if (!found.TryGetValue(part.Id, out var body)) continue;

            var normalised = body.Trim();
            try
            {
                Validate(normalised, part);
                if (shipped.EditableTextFor(part) == normalised) continue;
            }
            catch (InvalidOperationException)
            {
                continue;
            }

            Save(normalised, part);
            migrated.Add(part);
        }

        var archive = LegacyPath + ".migrated";
        if (File.Exists(archive)) File.Delete(archive);
        File.Move(LegacyPath, archive);
        return new Migration(migrated, archive);
    }
}

/// <summary>
/// Reads the single-file PROMPT.md format that prompt/ replaced.
/// </summary>
/// <remarks>
/// Kept for one job only: splitting a user's edited copy into part files the first time they run a
/// version that expects the directory. Nothing in the app sends a prompt through this type, and it
/// should be deleted a release after the split ships.
///
/// The marker search here is anchored to whole lines, which the shipped loader never was. That is
/// the bug the split was made to end -- a file that documented its own markers had them matched
/// inside the documentation, because the search took the first substring anywhere in the text.
/// Anyone whose custom prompt was a copy of the shipped one has that sentence in it, so migrating
/// with the original rule would carry the bug into their new part files.
/// </remarks>
public sealed class LegacyPromptFile(string template)
{
    private readonly string[] _lines = template.Replace("\r\n", "\n").Split('\n');

    public bool IsLegacyFormat => Block("SYSTEM") is not null;

    /// <summary>
    /// Every part this file can supply, keyed by <see cref="PromptPart.Id"/>.
    /// </summary>
    /// <remarks>
    /// Parts the file does not contain are simply absent -- an old prompt written before the summary
    /// stage existed has no summary block, and the caller falls back to the shipped one rather than
    /// failing, which is the whole reason per-part overrides exist.
    /// </remarks>
    public Dictionary<string, string> Parts()
    {
        var found = new Dictionary<string, string>(StringComparer.Ordinal);
        Add(found, PromptPart.System, Block("SYSTEM"));
        Add(found, PromptPart.Rewrite, Block("REWRITE"));
        Add(found, PromptPart.Summary, Block("SUMMARY"));
        foreach (var fidelity in Enum.GetValues<Fidelity>())
        {
            Add(found, PromptPart.Of(fidelity), Clause(fidelity.Id()));
        }
        foreach (var style in Enum.GetValues<RewriteStyle>().Where(s => s != RewriteStyle.Verbatim))
        {
            Add(found, PromptPart.Of(style), Clause($"style: {style.Id()}"));
        }
        foreach (var style in Enum.GetValues<SummaryStyle>())
        {
            Add(found, PromptPart.Of(style), Clause($"summary: {style.Id()}"));
        }
        return found;
    }

    private static void Add(Dictionary<string, string> into, PromptPart part, string? body)
    {
        if (body is not null) into[part.Id] = body;
    }

    /// <summary>Body between markers that each sit alone on their own line.</summary>
    private string? Block(string name)
    {
        int begin = -1, end = -1;
        for (var i = 0; i < _lines.Length; i++)
        {
            var trimmed = _lines[i].Trim();
            if (trimmed == $"<!-- BEGIN {name} -->") begin = i;
            else if (trimmed == $"<!-- END {name} -->" && begin >= 0 && end < 0) end = i;
        }
        if (begin < 0 || end <= begin) return null;

        var body = string.Join("\n", _lines[(begin + 1)..end]).Trim();
        return body.Length == 0 ? null : body;
    }

    /// <summary>The first fenced block under a `### name` heading line.</summary>
    private string? Clause(string name)
    {
        var heading = $"### {name}";
        var start = -1;
        for (var i = 0; i < _lines.Length; i++)
        {
            var trimmed = _lines[i].Trim();
            if (!trimmed.StartsWith(heading, StringComparison.Ordinal)) continue;

            // Tolerates the shipped file's `### light  *(default)*` without matching a longer
            // heading that merely starts the same way.
            var rest = trimmed[heading.Length..].Trim();
            if (rest.Length == 0 || !char.IsLetter(rest[0]))
            {
                start = i;
                break;
            }
        }
        if (start < 0) return null;

        var fences = new List<int>();
        for (var i = start; i < _lines.Length && fences.Count < 2; i++)
        {
            if (_lines[i].Trim() == "```") fences.Add(i);
        }
        if (fences.Count < 2) return null;

        var body = string.Join("\n", _lines[(fences[0] + 1)..fences[1]]).Trim();
        return body.Length == 0 ? null : body;
    }
}
