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
/// The absence of a style is the empty string, which sends nothing. That is what the retired
/// `.spoken` did and what an upgrading install keeps, but it is no longer what a *new* install
/// starts with — see `DictationExample.seeding`.
public enum DictationPreset: String, CaseIterable, Sendable, Codable {
    /// First, and what a new install starts with. See `DictationExample.seeding`.
    case prose
    case chat
    case notes

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
    /// What a brand-new install starts with.
    ///
    /// Empty used to be the default, and it had one real virtue: the shipped request was the one
    /// every measured number in `docs/PROMPT.md` described. It also meant a fresh install's
    /// transcripts were laid out however the model felt like that day, which is the complaint the
    /// whole formatting series started from — a default of "no answer" is still an answer, and it
    /// was the least predictable one available.
    public static let defaultPreset: DictationPreset = .prose

    /// The example a fresh install starts with, or nil when there is nothing to do.
    ///
    /// - Parameter stored: the persisted value, or nil when the key has never been written. The
    ///   distinction is the whole function: an empty string is somebody who pressed Clear and meant
    ///   it, and seeding over that would put words back they had just removed. Only the absence of
    ///   the key is a fresh install.
    /// - Returns: the text to store; nil when the install already has an answer, and nil when the
    ///   preset's file could not be read — in which case the key stays absent and the next launch
    ///   tries again.
    public static func seeding(
        stored: String?, presetText: (DictationPreset) -> String?
    ) -> String? {
        guard stored == nil else { return nil }
        guard let text = presetText(defaultPreset) else { return nil }
        return Typography.sanitizedSample(text)
    }

    /// - Returns: the text for the box, or **nil** when the answer is not knowable yet — a preset
    ///   this build recognises whose file could not be read. Nil is not "no style": a caller that
    ///   treated it as one would clear the retired keys and destroy the only record of what the
    ///   user had chosen, over something as temporary as an unreadable directory. Keep the keys
    ///   and try again on the next launch.
    public static func migrating(
        legacyStyle: String?,
        legacyCustom: String?,
        presetText: (DictationPreset) -> String?
    ) -> String? {
        let name = (legacyStyle ?? "").trimmed.lowercased()
        if name == "custom" { return Typography.sanitizedSample(legacyCustom ?? "") }
        if let preset = DictationPreset(rawValue: name) {
            guard let text = presetText(preset) else { return nil }
            return Typography.sanitizedSample(text)
        }
        // `spoken`, absent, or a value this build does not know. All three mean the box is empty,
        // which sends nothing — the behaviour `spoken` had, and the safe answer for a name from a
        // future build whose text this one could not resolve even with the files in front of it.
        return ""
    }
}
