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

    public func capturesEscape(whileDictationIsActive isActive: Bool) -> Bool {
        self == .escape && isActive
    }
}
