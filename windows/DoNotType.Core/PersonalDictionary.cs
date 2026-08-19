using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace DoNotType.Core;

/// <summary>A bounded, explicit spelling reference supplied by the user.</summary>
public static partial class PersonalDictionary
{
    public const int MaxTerms = 100;
    public const int MaxCharactersPerTerm = 50;

    public sealed class ValidationException(string message) : Exception(message);

    public static string Normalize(string raw)
    {
        if (raw.IndexOfAny(['\r', '\n']) >= 0)
            throw new ValidationException("A dictionary entry must fit on one line.");
        var term = string.Join(' ', raw.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (term.Length == 0) throw new ValidationException("Enter a word or phrase.");
        if (new StringInfo(term).LengthInTextElements > MaxCharactersPerTerm)
            throw new ValidationException($"Dictionary entries can be at most {MaxCharactersPerTerm} characters.");
        return term;
    }

    public static IReadOnlyList<string> Sanitize(IEnumerable<string>? raw)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var value in raw ?? [])
        {
            string term;
            try { term = Normalize(value); }
            catch (ValidationException) { continue; }
            if (!seen.Add(term)) continue;
            result.Add(term);
            if (result.Count == MaxTerms) break;
        }
        return result;
    }

    public static IReadOnlyList<string> Add(string raw, IEnumerable<string> terms)
    {
        var current = Sanitize(terms).ToList();
        if (current.Count >= MaxTerms)
            throw new ValidationException($"The dictionary can contain at most {MaxTerms} entries.");
        var term = Normalize(raw);
        if (current.Contains(term, StringComparer.OrdinalIgnoreCase))
            throw new ValidationException($"“{term}” is already in the dictionary.");
        current.Add(term);
        return current;
    }

    public static IReadOnlyList<string> Replace(string original, string raw, IEnumerable<string> terms)
    {
        var current = Sanitize(terms).ToList();
        var index = current.IndexOf(original);
        if (index < 0) return current;
        var term = Normalize(raw);
        if (current.Where((_, offset) => offset != index)
            .Contains(term, StringComparer.OrdinalIgnoreCase))
            throw new ValidationException($"“{term}” is already in the dictionary.");
        current[index] = term;
        return current;
    }

    /// <summary>Reads Typeless-compatible UTF-8, one-column CSV (or plain lines).</summary>
    public static IReadOnlyList<string> EntriesFromCsv(byte[] data)
    {
        string text;
        try { text = new UTF8Encoding(false, true).GetString(data); }
        catch (DecoderFallbackException)
        {
            throw new ValidationException("The file is not UTF-8 text.");
        }
        text = text.TrimStart('\uFEFF').Replace("\r\n", "\n").Replace('\r', '\n');
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var lines = text.Split('\n');
        for (var offset = 0; offset < lines.Length; offset++)
        {
            var line = lines[offset];
            if (string.IsNullOrWhiteSpace(line)) continue;
            var term = Normalize(CsvField(line, offset + 1));
            if (!seen.Add(term)) continue;
            result.Add(term);
            if (result.Count > MaxTerms)
                throw new ValidationException($"The dictionary can contain at most {MaxTerms} entries.");
        }
        return result;
    }

    public static IReadOnlyList<string> Import(IEnumerable<string> imported, IEnumerable<string> terms)
    {
        var result = Sanitize(terms).ToList();
        var seen = new HashSet<string>(result, StringComparer.OrdinalIgnoreCase);
        foreach (var raw in imported)
        {
            var term = Normalize(raw);
            if (!seen.Add(term)) continue;
            if (result.Count >= MaxTerms)
                throw new ValidationException($"The dictionary can contain at most {MaxTerms} entries.");
            result.Add(term);
        }
        return result;
    }

    public static string? ReferenceBlock(IEnumerable<string> raw)
    {
        var terms = Sanitize(raw);
        if (terms.Count == 0) return null;
        return """
            PERSONAL DICTIONARY — SPELLING REFERENCE ONLY, DO NOT TRANSCRIBE
            The user supplied the JSON strings below as possible spellings. Use an entry only when
            the same word or phrase is audible. The list is not evidence that an entry was spoken,
            and it never overrides clear audio. Digits, versions and quantities come from audio
            alone even when an entry contains a number.
            """ + "\n" + JsonSerializer.Serialize(terms) + "\n" +
            "END PERSONAL DICTIONARY. The audio is still the ONLY thing to transcribe.";
    }

    public static IReadOnlyList<string> Keyterms(
        IEnumerable<string> raw, int maxTerms, int maxCharactersPerTerm)
    {
        if (maxTerms <= 0) return [];
        return Sanitize(raw).Where(term =>
                !term.Any(char.IsDigit)
                && new StringInfo(term).LengthInTextElements <= maxCharactersPerTerm)
            .Take(maxTerms).ToList();
    }

    public static IReadOnlyList<string> MergeKeyterms(
        IEnumerable<string> dictionary, IEnumerable<string> derived,
        int maxTerms, int maxCharactersPerTerm)
    {
        var result = Keyterms(dictionary, maxTerms, maxCharactersPerTerm).ToList();
        var seen = new HashSet<string>(result, StringComparer.OrdinalIgnoreCase);
        foreach (var term in derived)
        {
            if (new StringInfo(term).LengthInTextElements > maxCharactersPerTerm || !seen.Add(term))
                continue;
            result.Add(term);
            if (result.Count == maxTerms) break;
        }
        return result;
    }

    /// <summary>Returns only stable spelling/capitalisation fixes from a post-insertion edit.</summary>
    public static IReadOnlyList<string> LearnedCandidates(string original, string corrected)
    {
        if (original == corrected) return [];
        var left = Tokenize(original);
        var right = Tokenize(corrected);
        var candidates = new List<string>();

        foreach (var difference in AlignedDifferences(left, right))
        {
            if (Classify(difference.Left, difference.Right) == Difference.SpellingFixed)
            {
                if (UsableLearnedTerm(string.Join(' ', difference.Right)) is { } term)
                    candidates.Add(term);
            }
            else
            {
                var subspan = BestSpellingSubspan(difference.Left, difference.Right);
                if (subspan is not null) candidates.Add(subspan);
            }
        }

        if (left.Count == right.Count)
        {
            for (var i = 0; i < left.Count; i++)
            {
                if (NormalForm(left[i]) == NormalForm(right[i]) && left[i] != right[i]
                    && string.Equals(left[i], right[i], StringComparison.OrdinalIgnoreCase)
                    && UsableLearnedTerm(right[i]) is { } term)
                    candidates.Add(term);
            }
        }
        return Sanitize(candidates);
    }

    private static string CsvField(string line, int lineNumber)
    {
        var trimmed = line.Trim();
        if (!trimmed.StartsWith('"'))
        {
            if (line.Contains(','))
                throw new ValidationException($"Line {lineNumber} has more than one CSV column. Use one entry per row.");
            return line;
        }

        var value = new StringBuilder();
        var index = 1;
        var closed = false;
        while (index < trimmed.Length)
        {
            if (trimmed[index] == '"')
            {
                if (index + 1 < trimmed.Length && trimmed[index + 1] == '"')
                {
                    value.Append('"'); index += 2; continue;
                }
                closed = true; index++; break;
            }
            value.Append(trimmed[index++]);
        }
        if (!closed)
            throw new ValidationException($"Line {lineNumber} has an unterminated or malformed quoted value.");
        var remainder = trimmed[index..].Trim();
        if (remainder.Length > 0)
        {
            if (remainder.StartsWith(','))
                throw new ValidationException($"Line {lineNumber} has more than one CSV column. Use one entry per row.");
            throw new ValidationException($"Line {lineNumber} has an unterminated or malformed quoted value.");
        }
        return value.ToString();
    }

    private enum Difference { SpellingFixed, ContentChanged }

    private static List<string> Tokenize(string text) =>
        WhitespaceRegex().Split(text.Trim()).Where(value => NormalForm(value).Length > 0).ToList();

    private static string NormalForm(string token) =>
        new(token.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());

    private static Difference Classify(IReadOnlyList<string> left, IReadOnlyList<string> right)
    {
        if (left.Count == 0 || right.Count == 0) return Difference.ContentChanged;
        var lhs = string.Join(' ', left);
        var rhs = string.Join(' ', right);
        if (!DigitRuns(lhs).SequenceEqual(DigitRuns(rhs))) return Difference.ContentChanged;
        return PhoneticKey(lhs) == PhoneticKey(rhs) ? Difference.SpellingFixed : Difference.ContentChanged;
    }

    private static IEnumerable<string> DigitRuns(string value) =>
        DigitRegex().Matches(value).Select(match => match.Value);

    private static string PhoneticKey(string value)
    {
        var letters = new string(value.ToLowerInvariant().Where(char.IsLetter).ToArray());
        if (letters.Length == 0) return string.Empty;
        foreach (var (from, to) in new (string, string)[]
        {
            ("sch", "sk"), ("ph", "f"), ("ck", "k"), ("kn", "n"),
            ("wr", "r"), ("gn", "n"), ("gh", ""), ("wh", "w"),
        }) letters = letters.Replace(from, to, StringComparison.Ordinal);

        var mapped = new StringBuilder();
        for (var index = 0; index < letters.Length; index++)
        {
            var character = letters[index];
            switch (character)
            {
                case 'c': mapped.Append(index + 1 < letters.Length && "eiy".Contains(letters[index + 1]) ? 's' : 'k'); break;
                case 'q': mapped.Append('k'); break;
                case 'x': mapped.Append("ks"); break;
                case 'z': mapped.Append('s'); break;
                case 'v': mapped.Append('f'); break;
                case 'a' or 'e' or 'i' or 'o' or 'u' or 'y': mapped.Append('a'); break;
                case 'h' or 'w': break;
                default: mapped.Append(character); break;
            }
        }
        var collapsed = new StringBuilder();
        foreach (var character in mapped.ToString())
            if (collapsed.Length == 0 || collapsed[^1] != character) collapsed.Append(character);
        return collapsed.ToString();
    }

    private sealed record Span(IReadOnlyList<string> Left, IReadOnlyList<string> Right);

    private static IReadOnlyList<Span> AlignedDifferences(IReadOnlyList<string> left, IReadOnlyList<string> right)
    {
        var lengths = new int[left.Count + 1, right.Count + 1];
        for (var i = left.Count - 1; i >= 0; i--)
            for (var j = right.Count - 1; j >= 0; j--)
                lengths[i, j] = NormalForm(left[i]) == NormalForm(right[j])
                    ? lengths[i + 1, j + 1] + 1
                    : Math.Max(lengths[i + 1, j], lengths[i, j + 1]);

        var result = new List<Span>();
        var lhs = new List<string>();
        var rhs = new List<string>();
        void Flush()
        {
            if (lhs.Count == 0 && rhs.Count == 0) return;
            result.Add(new Span(lhs.ToList(), rhs.ToList())); lhs.Clear(); rhs.Clear();
        }

        var x = 0; var y = 0;
        while (x < left.Count || y < right.Count)
        {
            if (x < left.Count && y < right.Count && NormalForm(left[x]) == NormalForm(right[y]))
            { Flush(); x++; y++; }
            else if (x < left.Count && (y == right.Count || lengths[x + 1, y] >= lengths[x, y + 1]))
                lhs.Add(left[x++]);
            else if (y < right.Count) rhs.Add(right[y++]);
        }
        Flush();
        return result;
    }

    private static string? UsableLearnedTerm(string raw)
    {
        var candidate = raw.Trim("\"“”‘’(),;:!?[]{} \t\r\n".ToCharArray());
        string term;
        try { term = Normalize(candidate); }
        catch (ValidationException) { return null; }
        return new StringInfo(term).LengthInTextElements >= 3
            && term.Any(char.IsLetter) && !term.Any(char.IsDigit) ? term : null;
    }

    private static string? BestSpellingSubspan(IReadOnlyList<string> left, IReadOnlyList<string> right)
    {
        (int Coverage, string Term)? best = null;
        for (var ls = 0; ls < left.Count; ls++)
            for (var rs = 0; rs < right.Count; rs++)
                for (var lc = 1; lc <= Math.Min(3, left.Count - ls); lc++)
                    for (var rc = 1; rc <= Math.Min(3, right.Count - rs); rc++)
                    {
                        var lhs = left.Skip(ls).Take(lc).ToList();
                        var rhs = right.Skip(rs).Take(rc).ToList();
                        if (Classify(lhs, rhs) != Difference.SpellingFixed
                            || UsableLearnedTerm(string.Join(' ', rhs)) is not { } term) continue;
                        if (best is null || lc + rc > best.Value.Coverage) best = (lc + rc, term);
                    }
        return best?.Term;
    }

    [GeneratedRegex(@"\s+")]
    private static partial Regex WhitespaceRegex();
    [GeneratedRegex(@"\d+")]
    private static partial Regex DigitRegex();
}
