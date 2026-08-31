/// What the phone's keyboard will do with the next dictation.
///
/// Three values because the second stage has three answers, which the type system has said for a
/// while and the interface did not. The mode control on both keyboards was a two-state toggle over
/// `dictate`/`rewrite` while a target language in Settings quietly overrode both — so the chip had
/// to display a third state it could not offer, and going from one to another meant leaving the
/// field, opening the app, and coming back. This is the same three cases `TranscriptMode` has,
/// named for what the user is choosing rather than for what the pipeline does with it.
///
/// Only the phones have one. A desktop chooses its mode by *which key it is holding* — the main key
/// is verbatim and the second key rewrites — so a persistent chip would be a second answer to a
/// question the keyboard already answers. See `docs/PARITY.md`.
public enum LiveMode: String, CaseIterable, Sendable, Codable {
    /// Verbatim. The default, and the product.
    case dictate
    /// Verbatim first, then rewritten in the configured style.
    case rewrite
    /// Verbatim first, then written again in the configured language.
    case translate

    public static let `default`: LiveMode = .dictate

    /// What the chip says. Short, because it is 68dp wide on Android and 86pt on iOS.
    public var label: String {
        switch self {
        case .dictate: "Dictate"
        case .rewrite: "Rewrite"
        case .translate: "Translate"
        }
    }

    /// Whether this mode can run right now, and what to say when it cannot.
    ///
    /// The picker asks before it offers: a mode that is greyed out with a reason beats one that is
    /// offered and then silently does something else, which is what the target-language override
    /// used to do to the rewrite chip.
    ///
    /// - Parameters:
    ///   - provider: the selected backend.
    ///   - language: the configured target language, which only `translate` needs.
    ///   - hasKey: whether a usable key exists for a backend.
    public func availability(
        provider: ProviderKind, language: String, hasKey: (ProviderKind) -> Bool
    ) -> RewriteAvailability {
        switch self {
        case .dictate:
            // One stage, so there is nothing here that can be missing beyond the key the dictation
            // itself needs, which every client reports where it is actually noticed.
            return .available
        case .rewrite:
            return .resolve(provider: provider, job: .rewriting, hasKey: hasKey)
        case .translate:
            guard !TranslationTarget.sanitized(language).isEmpty else { return .noTargetLanguage }
            return .resolve(provider: provider, job: .translating, hasKey: hasKey)
        }
    }

    /// The stage this mode asks for, given the style and language the user has configured.
    ///
    /// One resolver rather than the same three-branch conditional in four call sites, and it is the
    /// place the empty cases are decided: a translation with no language and a rewrite with no
    /// style are both just a dictation, because the alternative is a second request that asks a
    /// model to do something unspecified to a transcript.
    public func stage(style: RewriteStyle, language: String) -> TranscriptMode {
        switch self {
        case .dictate:
            return .verbatim
        case .rewrite:
            return style.isRewrite ? .rewrite(style) : .verbatim
        case .translate:
            let target = TranslationTarget.sanitized(language)
            return target.isEmpty ? .verbatim : .translate(target)
        }
    }
}
