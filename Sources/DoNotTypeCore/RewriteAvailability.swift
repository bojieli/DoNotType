import Foundation

/// Whether the rewrite stage can run at all, and what to say when it cannot.
///
/// Every client asked this question separately and got a different answer. macOS never asked and
/// offered the control regardless; Windows warned but left it enabled; iOS and Android asked
/// `!provider.isSpeechRecognition || secondStageBackend != nil`, which is a question about the
/// *kind* of backend and not about whether one is usable — so a fresh install with no key at all
/// offered a rewrite that could not run. The default provider moving from a recogniser to a model
/// turned that from latent to visible.
///
/// One rule, in the core, hand-ported to C# and Kotlin with the strings word-identical. The reason
/// text is the whole point: a control that is greyed out without saying why is barely better than
/// one that is missing, and a missing one is how this feature came to look absent entirely.
public enum RewriteAvailability: Sendable, Equatable {
    case available
    /// No key for the selected backend, so nothing can run — not a rewrite, not a transcript.
    case noKey
    /// The selected backend turns audio into text and cannot turn text into text, and no other
    /// configured backend can either.
    case backendCannotRewrite(ProviderKind)

    public var isAvailable: Bool { self == .available }

    /// One sentence saying why not, and what to do about it. Nil when the stage can run.
    ///
    /// Must stay word-identical across the four clients — see `docs/PARITY.md`. Someone comparing
    /// a phone to a laptop is comparing the same product.
    public var reason: String? {
        switch self {
        case .available:
            nil
        case .noKey:
            "Add an API key first — without one nothing can run, rewriting included."
        case .backendCannotRewrite(let kind):
            "\(kind.displayName) only transcribes audio and cannot rewrite text. Add a key for a "
                + "backend that can, and rewriting will use it."
        }
    }

    /// Resolves against whatever the client uses to store keys.
    ///
    /// - Parameters:
    ///   - provider: the selected backend.
    ///   - hasKey: whether a usable key exists for a backend. Passed in rather than read here so
    ///     the Keychain, DPAPI and SharedPreferences all answer the same question.
    public static func resolve(
        provider: ProviderKind, hasKey: (ProviderKind) -> Bool
    ) -> RewriteAvailability {
        // Asked first, and about the *selected* backend: with no key the dictation itself fails, so
        // a message about rewriting would be answering the second question while the first is still
        // wrong.
        guard hasKey(provider) else { return .noKey }

        // Covers model providers and xAI alike. `supportsTextGeneration` is deliberately not the
        // negation of `isSpeechRecognition` — xAI is a recogniser that also sells chat, and the
        // same key reaches both.
        if provider.supportsTextGeneration { return .available }

        // A recogniser with no text endpoint borrows a second stage from another configured
        // backend, which is the behaviour file transcription already had.
        let borrowed = ProviderKind.allCases.first { $0.supportsTextGeneration && hasKey($0) }
        return borrowed == nil ? .backendCannotRewrite(provider) : .available
    }
}
