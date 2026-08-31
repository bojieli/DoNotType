import Foundation

/// A named starting point for the dictation example — a button, never a stored setting.
///
/// This used to be `DictationStyle`, a five-case enum the user picked from and the app persisted.
/// That shape is what made the control unusable: the label had to compress a whole instruction into
/// a dash-clause, so `Chat — short lines, light punctuation` read as a mood and behaved as a rule,
/// and somebody who wanted the mood got line breaks they never asked for and could not trace. The
/// instruction was three files away from the only place it was described.
///
/// The instruction is now the control. A preset drops its text into the example box, where it can
/// be read and edited before it is used, and what the user ends up with is a string rather than a
/// case. Presets can therefore be added, renamed and reworded without changing a stored value or
/// migrating anybody, because nothing stores them.
///
/// The absence of a style is the empty string, which sends nothing — the same default as the old
/// `.spoken`, and still the thing that keeps every measured number in `docs/PROMPT.md` describing
/// the request a fresh install actually makes.
public enum DictationPreset: String, CaseIterable, Sendable, Codable {
    case chat
    case notes
    case prose

    /// The button's text. A name and nothing else: what it means is the text it drops in the box,
    /// which is on screen the moment it is pressed.
    public var label: String {
        switch self {
        case .chat: "Chat"
        case .notes: "Notes"
        case .prose: "Prose"
        }
    }

    /// One line under the button, for the gap between pressing and reading.
    ///
    /// Deliberately about *shape*, never about feel. The old labels promised a register and
    /// delivered a layout rule; these say what the text will physically look like, and the example
    /// box says the rest in the instruction's own words.
    public var shape: String {
        switch self {
        case .chat: "Short lines, one thought each"
        case .notes: "One point per line"
        case .prose: "Full sentences, paragraphs"
        }
    }
}

/// How an older install's dictation-style setting becomes an example.
///
/// One named rule rather than the same three-branch conditional in four clients and two importers.
/// It has to be a *rule* and not a default, because the whole point of the migration is that
/// nobody's dictations change on upgrade: somebody who chose Chat had `chat.md`'s words in their
/// request, so after upgrading they have those same words in their box, byte for byte, and can
/// now see and edit them.
///
/// - Parameters:
///   - legacyStyle: the retired `dictationStyle` value — `spoken`, `chat`, `notes`, `prose` or
///     `custom` — from settings or from a transfer profile written by an older build.
///   - legacyCustom: the retired free-text field, which only `custom` ever used.
///   - presetText: resolves a preset to its shipped (or user-overridden) text.
public enum DictationExample {
    public static func migrating(
        legacyStyle: String?,
        legacyCustom: String?,
        presetText: (DictationPreset) -> String?
    ) -> String {
        let name = (legacyStyle ?? "").trimmed.lowercased()
        if name == "custom" { return Typography.sanitizedSample(legacyCustom ?? "") }
        if let preset = DictationPreset(rawValue: name), let text = presetText(preset) {
            return Typography.sanitizedSample(text)
        }
        // `spoken`, absent, or a value this build does not know. All three mean the box is empty,
        // which sends nothing — the behaviour `spoken` had, and the safe answer for a name from a
        // future build whose text this one cannot resolve.
        return ""
    }
}
