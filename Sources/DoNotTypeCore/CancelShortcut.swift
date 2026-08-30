/// The key that abandons an active dictation.
///
/// The policy lives in the core target so the most important invariant is testable: choosing
/// Escape does not turn it into an application-wide shortcut. It is captured only while a
/// recording or transcription is actually in flight.
public enum CancelShortcut: String, CaseIterable, Sendable {
    case escape
    case disabled

    public var label: String {
        switch self {
        case .escape: "Escape"
        case .disabled: "None"
        }
    }

    /// What the recording overlay says while the dictation can still be abandoned.
    ///
    /// Empty when nothing is bound, and that is the important half. An overlay naming a key that
    /// is not intercepted is worse than one naming none: Escape then still belongs to whatever
    /// application is in front, and pressing it does something else entirely.
    ///
    /// "Esc" rather than "Escape" because this shares one line with the finish-and-send hint and
    /// the pill is not resized for it. The settings window, which has room, uses `label`.
    public var overlayHint: String {
        switch self {
        case .escape: "Esc to cancel"
        case .disabled: ""
        }
    }

    public func capturesEscape(whileDictationIsActive isActive: Bool) -> Bool {
        self == .escape && isActive
    }
}
