import Foundation

/// How much cleanup the transcript may receive.
///
/// This is the dial that separates DoNotType from a rewriting tool: even `tidy` is only allowed
/// to change typography, never words. See `prompt/fidelity/` for the clauses these map onto.
public enum Fidelity: String, CaseIterable, Sendable, Codable {
    /// Every um, uh, false start and repetition, exactly where it occurred.
    case raw
    /// Fillers and stutters dropped; every real word kept verbatim. The default.
    case light
    /// `light`, plus sentence casing and punctuation. Words still unchanged.
    case tidy

    public static let `default`: Fidelity = .light
}
