import Foundation

/// What happens where Chinese or Japanese text meets Latin letters and digits.
///
/// A setting rather than a rule because there is no single right answer — the space is
/// conventional in Chinese typography and plenty of people dislike it — but there *is* a wrong
/// answer, which is what the product did before: whatever the model felt like that request. The
/// same sentence dictated twice came back spaced once and tight once.
public enum TypographySpacing: String, CaseIterable, Sendable, Codable {
    /// One space at every boundary. The convention most Chinese style guides ask for, and the
    /// default: a rule the user can predict beats a coin flip in either direction.
    case spaced
    /// No space at any boundary.
    case tight
    /// Whatever came back. Not the default, because this is the behaviour that was reported as a
    /// bug — but it is the honest escape hatch for anyone whose text this transform gets wrong,
    /// and for anyone who would rather have the model's judgement than a rule.
    case unchanged

    public static let `default`: TypographySpacing = .spaced

    public var label: String {
        switch self {
        case .spaced: "Spaced — one space where Chinese meets Latin"
        case .tight: "Tight — no space where Chinese meets Latin"
        case .unchanged: "Unchanged — however the model wrote it"
        }
    }
}

/// Typography applied to a finished transcript, deterministically.
///
/// This is the half of the formatting problem that does not belong in a prompt. A model asked to
/// space Chinese and Latin consistently does it most of the time, which is the worst available
/// outcome: consistent output and occasional output are told apart only by reading, and the thing
/// being read is the thing the user has stopped watching because they were dictating. The rules
/// here are arithmetic over characters, so they hold on every request, for every backend, at no
/// latency and no tokens.
///
/// **It never changes a word.** Every rule adds or removes horizontal space; nothing here inserts
/// punctuation, converts a character, reorders anything, or deletes anything that is not a space.
/// That boundary is the reason the feature is split in two: asking the model for full-width commas
/// instead of spaces between clauses *is* a content change — a comma the speaker did not say — so
/// it is asked for in `prompt/typography.md` where it can be refused, rather than imposed here
/// where it could not be.
///
/// Ported by hand to C# (`windows/DoNotType.Core/Typography.cs`) and Kotlin
/// (`android/.../core/Typography.kt`). The three suites assert the same table.
public enum Typography {

    /// The most of a formatting example that is sent.
    ///
    /// A cap rather than a validation error, and the settings screen says the number: this is one
    /// or two sentences demonstrating spacing and punctuation, and a page of prose pasted into it
    /// would be a page of prose on every request. Long enough for a sentence in each script plus a
    /// list, short enough that nobody notices the tokens.
    public static let maxSampleCharacters = 500

    /// The user's formatting example, as it will be sent.
    ///
    /// Cleaned rather than rejected. The field is free text on purpose — the whole point is to
    /// demonstrate a convention this codebase has no name for — so the only things removed are the
    /// ones that would break the block it is pasted into: control characters, and more than one
    /// blank line in a row.
    public static func sanitizedSample(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        cleaned = String(
            cleaned.unicodeScalars.filter { scalar in
                scalar == "\n" || scalar == "\t" || !isControl(scalar)
            }.map(Character.init))
        while cleaned.contains("\n\n\n") {
            cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        cleaned = cleaned.trimmed
        return cleaned.count > maxSampleCharacters
            ? String(cleaned.prefix(maxSampleCharacters)).trimmed : cleaned
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    /// Applies the user's spacing rule and removes space that no convention allows.
    ///
    /// Idempotent: normalising twice is normalising once, which matters because a split recording
    /// is normalised per chunk and again after stitching.
    public static func normalize(_ text: String, spacing: TypographySpacing) -> String {
        guard spacing != .unchanged, !text.isEmpty else { return text }

        let scalars = Array(text.unicodeScalars)
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(scalars.count + 8)

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]

            guard isHorizontalSpace(scalar) else {
                // A boundary the model wrote without a space. Only `spaced` has anything to add;
                // `tight` has nothing to do until it meets a space.
                if spacing == .spaced, let previous = out.last, isScriptBoundary(previous, scalar) {
                    out.append(" ")
                }
                out.append(scalar)
                index += 1
                continue
            }

            // The whole run at once, so two spaces at a boundary collapse to the one the rule
            // asks for rather than to two.
            var end = index
            while end < scalars.count, isHorizontalSpace(scalars[end]) { end += 1 }
            let previous = out.last
            let next = end < scalars.count ? scalars[end] : nil

            guard let previous, let next else {
                // Leading and trailing space is layout the speaker or the caller owns — an indent,
                // or the join between two stitched chunks — and is left exactly as it arrived.
                out.append(contentsOf: scalars[index..<end])
                index = end
                continue
            }

            if isFullWidthPunctuation(previous) || isFullWidthPunctuation(next) {
                // Not a preference. A full-width mark carries its own space inside the glyph, so
                // no convention in any of these scripts puts another one beside it — which is why
                // this runs under both settings. The reported symptom was an extra space after a
                // full stop, arriving on some sentences and not others.
                index = end
                continue
            }

            if isScriptBoundary(previous, next) {
                if spacing == .spaced { out.append(" ") }
                index = end
                continue
            }

            out.append(contentsOf: scalars[index..<end])
            index = end
        }

        var result = String.UnicodeScalarView()
        result.append(contentsOf: out)
        return String(result)
    }

    // MARK: - Character classes

    /// Space that is typography. A newline is not, and neither is anything else that carries
    /// structure: this transform must be unable to join two lines together.
    static func isHorizontalSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t"
    }

    /// Han ideographs and Japanese kana.
    ///
    /// Hangul is deliberately absent. Korean already separates its words with spaces, so `tight`
    /// would take out a space the language requires — a setting about Chinese and Latin has no
    /// business editing Korean. Kana is included so that Japanese is treated consistently within
    /// itself: excluding it would space `Web開発` and not `Webかいはつ`, which is the inconsistency
    /// this whole type exists to remove.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        switch value {
        case 0x3400...0x4DBF,  // CJK Unified Ideographs Extension A
            0x4E00...0x9FFF,  // CJK Unified Ideographs
            0xF900...0xFAFF,  // CJK Compatibility Ideographs
            0x20000...0x2A6DF,  // Extension B
            0x2A700...0x2EBEF,  // Extensions C through F
            0x2F800...0x2FA1F:  // Compatibility Ideographs Supplement
            return true
        case 0x3041...0x30FF:
            // The one exception in the kana block: ・ is punctuation, and spacing around it would
            // turn `A・B` into `A ・ B`.
            return value != 0x30FB
        case 0x31F0...0x31FF:  // Katakana phonetic extensions
            return true
        default:
            return false
        }
    }

    /// The Latin side of a boundary: letters and digits only.
    ///
    /// Symbols are deliberately excluded, which makes `50%的人` come back unchanged rather than as
    /// `50% 的人`. Conservative on purpose — a rule that fires on punctuation has far more ways to
    /// be wrong, and nobody reported symbols.
    static func isLatinAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        // × and ÷ sit inside the Latin-1 letter range and are neither.
        if value == 0x00D7 || value == 0x00F7 { return false }
        switch value {
        case 0x30...0x39,  // 0-9
            0x41...0x5A,  // A-Z
            0x61...0x7A,  // a-z
            0x00C0...0x024F:  // Latin-1 Supplement, Latin Extended-A and B
            return true
        default:
            return false
        }
    }

    /// Marks that already contain their own space. Latin quotation marks are excluded: `"` and `'`
    /// are used in English exactly as often, and stripping the space beside one would be editing
    /// English prose on behalf of a Chinese setting.
    static func isFullWidthPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3001...0x303F,  // 、。〈〉《》「」『』【】〔〕… — and the rest of CJK punctuation
            0x30FB,  // ・
            0xFF01...0xFF0F,  // ！＂＃＄％＆＇（）＊＋，－．／
            0xFF1A...0xFF20,  // ：；＜＝＞？＠
            0xFF3B...0xFF40,  // ［＼］＾＿｀
            0xFF5B...0xFF65:  // ｛｜｝～｟｠｡｢｣､･
            return true
        default:
            return false
        }
    }

    static func isScriptBoundary(_ left: Unicode.Scalar, _ right: Unicode.Scalar) -> Bool {
        (isCJK(left) && isLatinAlphanumeric(right))
            || (isLatinAlphanumeric(left) && isCJK(right))
    }
}
