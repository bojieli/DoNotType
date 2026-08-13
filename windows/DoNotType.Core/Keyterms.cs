using System.Text;

namespace DoNotType.Core;

/// <summary>
/// Derives a short list of spellings from the screen, for backends whose only grounding channel is
/// a word list. Port of the macOS <c>Keyterms</c>; the two must agree or the platforms measure
/// different things.
///
/// <para><b>Why this exists, given that the encoder deliberately does no analysis.</b>
/// <see cref="ContextEncoder"/> clips, labels and orders text that was literally on screen, and the
/// README names term extraction as the thing this project does not do. That rule was written about
/// a <em>model</em> provider, where obeying it is free. A recogniser has no such channel: Deepgram
/// accepts a list of terms and nothing else, so for those backends the choice is not "raw context
/// versus extracted terms" but "extracted terms versus no grounding at all". It is still the weaker
/// mechanism and it is off by default.</para>
///
/// <para><b>The rule that is not negotiable.</b> Nothing containing a digit is ever emitted.
/// Substitution — hearing "Gemini 1.5" and writing the "3.5" that was on screen — is the failure
/// this project exists to prevent, and a keyterm list is blunter than a prompt: there is no
/// "reference only, do not transcribe" clause to attach, because the API has nowhere to put one.
/// A name has one correct spelling regardless of what was said; a number does not.</para>
/// </summary>
public static class Keyterms
{
    /// <summary>
    /// Ordered best-first, so truncating to a provider's cap keeps the most relevant terms.
    /// Ordering is by proximity to the caret rather than by frequency: what someone is about to
    /// dictate into predicts what they are about to say far better than what is repeated elsewhere.
    /// </summary>
    public static IReadOnlyList<string> Derive(
        ScreenContext context, int maxTerms = 100, int maxCharsPerTerm = 50)
    {
        if (maxTerms <= 0) return [];

        string?[] sources =
        [
            context.SelectedText,
            context.TextBeforeCaret,
            context.TextAfterCaret,
            context.WindowTitle,
            context.VisibleText,
        ];

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var terms = new List<string>();
        foreach (var source in sources)
        {
            if (string.IsNullOrEmpty(source)) continue;
            foreach (var candidate in Candidates(source))
            {
                if (candidate.Length > maxCharsPerTerm) continue;
                // The endpoint does its own matching, so two casings of one word would spend two
                // of a scarce hundred slots.
                if (!seen.Add(candidate)) continue;
                terms.Add(candidate);
                if (terms.Count == maxTerms) return terms;
            }
        }
        return terms;
    }

    /// <summary>Words worth biasing, in the order they appear.</summary>
    public static List<string> Candidates(string text) =>
        Tokenize(text).Where(IsWorthBiasing).Select(token => token.Text).ToList();

    public readonly record struct Token(string Text, bool StartsSentence);

    /// <summary>
    /// Characters that belong <em>inside</em> a term. Everything else ends one. Quotes, brackets
    /// and <c>=</c> are deliberately absent: splitting on whitespace alone produced
    /// <c>koffi.load('libContextHelper.dylib</c> and <c>--author="Li</c>, terms carrying an
    /// unmatched bracket that bias toward a string appearing nowhere.
    /// </summary>
    private const string WordPunctuation = "-_./'#@+";

    /// <summary>
    /// Splits into candidate terms, breaking on whitespace, punctuation <b>and script
    /// boundaries</b>.
    ///
    /// <para>The script boundary is the important one, and its absence made this feature useless
    /// for a bilingual user. Chinese is written without spaces, so a whitespace split glued every
    /// Latin term to the Han characters beside it and the genuinely hard words — Kubernetes,
    /// quillmark-sync — were lost or emitted as mixed-script blobs.</para>
    /// </summary>
    public static List<Token> Tokenize(string text)
    {
        var tokens = new List<Token>();
        var sentenceIsOpen = false;
        var current = new StringBuilder();

        void Flush(bool endsSentence = false)
        {
            var word = Trim(current.ToString());
            current.Clear();
            if (word.Length > 0)
            {
                tokens.Add(new Token(word, !sentenceIsOpen));
                sentenceIsOpen = true;
            }
            if (endsSentence) sentenceIsOpen = false;
        }

        for (var index = 0; index < text.Length; index++)
        {
            var character = text[index];
            if (IsCjkScript(character))
            {
                // Never itself a candidate: judging a Chinese term needs word segmentation.
                Flush();
            }
            else if (character == '.')
            {
                // Interior to `README.md`, terminal after `tokens.`; only a look-ahead separates
                // them, and treating every dot as word-internal loses sentence boundaries.
                var next = index + 1 < text.Length ? text[index + 1] : ' ';
                if (char.IsLetterOrDigit(next)) current.Append(character);
                else Flush(true);
            }
            else if (char.IsLetterOrDigit(character) || WordPunctuation.Contains(character))
            {
                current.Append(character);
            }
            else
            {
                Flush("!?。！？".Contains(character));
            }
        }
        Flush();
        return tokens;
    }

    /// <summary>
    /// Removes punctuation that survived the split but is not part of the word. One-sided on
    /// purpose: <c>--force</c> and <c>.gitignore</c> lead with punctuation that is part of them.
    /// </summary>
    private static string Trim(string raw)
    {
        var word = raw;
        while (word.Length > 0 && WordPunctuation.Contains(word[^1]))
        {
            // Keep a trailing dot only when an interior dot justifies it.
            if (word[^1] == '.' && word[..^1].Contains('.')) break;
            word = word[..^1];
        }
        while (word.Length > 0 && "'#@+_".Contains(word[0])) word = word[1..];
        return word;
    }

    /// <summary>
    /// CJK ideographs and the kana blocks — scripts written without spaces, used as a word
    /// boundary rather than as a candidate.
    /// </summary>
    public static bool IsCjkScript(char character) => character is
        (>= (char)0x3040 and <= (char)0x30FF) or
        (>= (char)0x3400 and <= (char)0x4DBF) or
        (>= (char)0x4E00 and <= (char)0x9FFF) or
        (>= (char)0xF900 and <= (char)0xFAFF) or
        (>= (char)0xFF00 and <= (char)0xFF65);

    /// <summary>
    /// Common words that survive the shape tests and should not spend a keyterm slot.
    /// Deliberately tiny, and acronyms are deliberately absent: HTTP, URL and their kind look like
    /// chrome but are exactly the tokens a recogniser mishears.
    /// </summary>
    public static readonly HashSet<string> Ignored = new(StringComparer.OrdinalIgnoreCase)
    {
        "the", "and", "but", "for", "with", "from", "this", "that", "new", "open", "save",
        "file", "edit", "view", "help", "window", "untitled", "document", "menu", "search",
    };

    public static bool IsWorthBiasing(Token token)
    {
        var word = token.Text;
        if (word.Length < 3) return false;
        if (Ignored.Contains(word)) return false;
        // Contractions reached the list as "capital mid-sentence, therefore a proper noun".
        // `O'Brien` must survive, so the test is on the suffix: short and lower case.
        if (IsContraction(word)) return false;
        // The rule from this type's documentation.
        if (word.Any(char.IsDigit)) return false;
        if (!word.Any(char.IsLetter)) return false;

        var letters = word.Where(char.IsLetter).ToArray();
        // ACRONYM
        if (letters.Length >= 2 && letters.All(char.IsUpper)) return true;
        // camelCase / PascalCase — an interior capital is a spelling a recogniser will not guess.
        if (word.Skip(1).Any(char.IsUpper)) return true;
        // kebab-case, snake_case, dotted or pathlike identifiers.
        if (IsJoinedIdentifier(word)) return true;
        // A command-line flag. `--no-edit` qualified as a joined identifier while `--author` did
        // not, an arbitrary distinction to someone who dictates both.
        var flagBody = word.TrimStart('-');
        if (word.StartsWith('-') && flagBody.Length >= 2 &&
            flagBody.All(c => char.IsLetter(c) || c == '-'))
        {
            return true;
        }
        // A capital mid-sentence is a proper noun; at the start of one it is only grammar.
        if (!token.StartsSentence && char.IsUpper(word[0])) return true;

        return false;
    }

    public static bool IsContraction(string word)
    {
        var index = word.IndexOfAny(['\'', '\u2019']);
        if (index < 0) return false;
        var suffix = word[(index + 1)..];
        return suffix.Length is > 0 and <= 3 && suffix.All(c => char.IsLower(c) && char.IsLetter(c));
    }

    private static bool IsJoinedIdentifier(string word)
    {
        const string joiners = "-_./:";
        var sawLetterBefore = false;
        for (var index = 0; index < word.Length; index++)
        {
            var character = word[index];
            if (joiners.Contains(character))
            {
                if (sawLetterBefore && index + 1 < word.Length && char.IsLetter(word[index + 1]))
                {
                    return true;
                }
            }
            else if (char.IsLetter(character))
            {
                sawLetterBefore = true;
            }
        }
        return false;
    }
}
