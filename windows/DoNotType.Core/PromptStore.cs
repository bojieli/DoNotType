namespace DoNotType.Core;

/// <summary>
/// The user's own copy of PROMPT.md, if they have edited one.
///
/// This is open-source software whose entire behaviour is a prompt, so making that prompt readable
/// but not editable would be an odd line to draw. The bundled version is the default and can always
/// be restored.
///
/// One caveat belongs in any UI that exposes this: the numbers in PROMPT.md's changelog were
/// measured against the bundled text, and an edited prompt invalidates them.
/// </summary>
public sealed class PromptStore(string directory)
{
    private const string FileName = "PROMPT.md";

    public string CustomPath => Path.Combine(directory, FileName);

    public bool HasCustomPrompt => File.Exists(CustomPath);

    /// <summary>The text in force: the user's copy when present, otherwise the bundled default.</summary>
    public string ActiveTemplate(string defaultPath)
    {
        if (HasCustomPrompt)
        {
            var text = File.ReadAllText(CustomPath);
            if (!string.IsNullOrWhiteSpace(text)) return text;
        }
        return File.ReadAllText(defaultPath);
    }

    public PromptBuilder Builder(string defaultPath) => new(ActiveTemplate(defaultPath));

    /// <summary>
    /// Validates before writing. A prompt that cannot build is a silently broken app, and the
    /// failure would surface mid-dictation rather than at the moment of editing.
    /// </summary>
    public void Save(string template)
    {
        Validate(template);
        Directory.CreateDirectory(directory);
        File.WriteAllText(CustomPath, template);
    }

    public void RestoreDefault()
    {
        if (HasCustomPrompt) File.Delete(CustomPath);
    }

    /// <summary>Checks that every substitution the app performs will succeed.</summary>
    public static void Validate(string template)
    {
        if (string.IsNullOrWhiteSpace(template))
        {
            throw new InvalidOperationException("The prompt is empty.");
        }
        if (!template.Contains("<!-- BEGIN SYSTEM -->") || !template.Contains("<!-- END SYSTEM -->"))
        {
            throw new InvalidOperationException(
                "The prompt needs a <!-- BEGIN SYSTEM --> … <!-- END SYSTEM --> block.");
        }
        if (!template.Contains("{{FIDELITY_RULE}}"))
        {
            throw new InvalidOperationException(
                "The system block needs a {{FIDELITY_RULE}} placeholder.");
        }

        // Every fidelity must resolve, or switching to one later would break mid-use.
        var builder = new PromptBuilder(template);
        foreach (var fidelity in Enum.GetValues<Fidelity>())
        {
            _ = builder.SystemInstruction(fidelity);
        }
    }
}
