import Foundation

/// How a dictation is written down, chosen from a short list or written by the user.
///
/// Not what it says — that is `Fidelity`, which decides how much of the speaker's own noise
/// survives, and neither of them may change a word. This is the shape of the written form: line
/// breaks, punctuation density, whether it reads like a chat message or a paragraph. The two dials
/// are separate because they answer different complaints, and stacking them is legal: `light`
/// fidelity in `chat` style is a real combination.
///
/// `spoken` is the default and sends **nothing**. That is load-bearing rather than tidy: every
/// measured number in `docs/PROMPT.md` describes the default request, and a clause added to it
/// unconditionally would invalidate the whole table at once.
///
/// `custom` is the other half of the same control, and the reason this is an enum rather than a
/// text box: most people want one of a few answers and should get it in one tap, and the people
/// who want something else should not be limited to the few we thought of. The custom text goes
/// through the same host block as every preset, so the "this is a style, not speech" framing and
/// the never-change-a-word rule apply to it too.
public enum DictationStyle: String, CaseIterable, Sendable, Codable {
    /// However the model would have written it. The shipped contract, unchanged.
    case spoken
    /// Short lines, minimal punctuation — how people type in a messaging app.
    case chat
    /// Sentence case, standard punctuation, a line break per point.
    case notes
    /// Complete sentences and paragraphs.
    case prose
    /// The user's own description or example.
    case custom

    public static let `default`: DictationStyle = .spoken

    /// Whether this style adds anything to the request. False only for `spoken`.
    public var isStyled: Bool { self != .spoken }

    /// Whether the clause comes from a file in `prompt/dictation-style/`. False for `custom`,
    /// whose clause is the user's own text, and for `spoken`, which has no clause at all.
    public var hasClauseFile: Bool { isStyled && self != .custom }

    public var label: String {
        switch self {
        case .spoken: "As spoken — however the model writes it"
        case .chat: "Chat — short lines, light punctuation"
        case .notes: "Notes — sentence case, one point per line"
        case .prose: "Prose — complete sentences and paragraphs"
        case .custom: "Custom — your own description or example"
        }
    }
}
