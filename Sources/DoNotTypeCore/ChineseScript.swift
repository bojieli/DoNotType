/// Which characters Chinese is written in.
///
/// Speech does not carry a writing system. Mandarin dictated by someone in Taipei and by someone
/// in Shanghai is the same audio, and the model has to pick — so it picks, differently, sometimes
/// inside one dictation. That was reported as the same complaint as the spacing: not that the
/// answer was wrong, but that it was not the same answer twice.
///
/// `spoken` is the shipped contract's own rule and the default, so choosing nothing sends nothing
/// extra: `prompt/system.md` already says Simplified unless the speaker asks otherwise, and the
/// measured numbers in `docs/PROMPT.md` describe that request exactly. The other two send
/// `prompt/typography.md` and take the question away from the model.
///
/// This is a script choice, never a translation. Wording and language stay governed by the
/// fidelity and language-preservation rules, which the formatting block restates rather than
/// relaxes.
public enum ChineseScript: String, CaseIterable, Sendable, Codable {
    case spoken
    case simplified
    case traditional

    public static let `default`: ChineseScript = .spoken

    /// Whether this is the shipped contract's own behaviour, and therefore adds nothing to a
    /// request.
    public var isDefault: Bool { self == .spoken }

    public var label: String {
        switch self {
        case .spoken: "Follow the speaker — Simplified unless they ask otherwise"
        case .simplified: "Always Simplified"
        case .traditional: "Always Traditional"
        }
    }
}
