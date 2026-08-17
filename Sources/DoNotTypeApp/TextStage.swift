import DoNotTypeCore
import Foundation

/// Which backend runs the second stage — the pass that rewrites or summarises a transcript that
/// already exists.
///
/// A separate question from which backend transcribes, because the two are not always the same
/// product: xAI transcribes on `grok-stt` and rewrites on a Grok chat model reached with the same
/// key, and a recogniser that sells nothing but recognition has to borrow a model backend or
/// admit it cannot do it. Both call sites — the rewrite hotkey and file transcription — ask here,
/// so they cannot disagree about what is possible.
@MainActor
enum TextStage {
    /// The service to run the second stage on, or nil when the caller's own service should do it
    /// because the selected backend is a language model, or when nothing configured can.
    ///
    /// Order matters. The selected provider's own text model comes first: it needs no second key,
    /// bills the account the user already chose, and keeps the dictation with one vendor.
    /// Borrowing another backend is the fallback, not the plan.
    static func service(instruction: String) -> TranscriptionService? {
        let settings = Settings.shared
        guard settings.provider.isSpeechRecognition else { return nil }

        if let model = settings.textModel, let key = settings.resolvedAPIKey(), !key.isEmpty,
            // `makeTextProvider` is itself optional, so a `try?` produces a nested one.
            let backend = (try? ProviderFactory.makeTextProvider(
                settings.provider, apiKey: key, endpoint: settings.endpoint))
                ?? nil
        {
            return TranscriptionService(
                provider: backend, model: model, systemInstruction: instruction,
                fidelity: settings.fidelity)
        }

        for kind in ProviderKind.allCases where !kind.isSpeechRecognition {
            guard let key = settings.resolvedAPIKey(for: kind), !key.isEmpty,
                let backend = try? settings.makeProvider(kind, apiKey: key)
            else { continue }
            return TranscriptionService(
                provider: backend, model: settings.model(for: kind),
                systemInstruction: instruction, fidelity: settings.fidelity)
        }
        return nil
    }

    /// Which backend it will be, for the UI to say so before anything is spent on finding out.
    static func provider() -> ProviderKind? {
        let settings = Settings.shared
        guard settings.provider.isSpeechRecognition else { return settings.provider }
        if settings.provider.supportsTextGeneration,
            settings.resolvedAPIKey()?.isEmpty == false
        {
            return settings.provider
        }
        return ProviderKind.allCases.first {
            !$0.isSpeechRecognition && (settings.resolvedAPIKey(for: $0)?.isEmpty == false)
        }
    }

    /// The model that stage will run, paired with `provider()`.
    static func model(for kind: ProviderKind) -> String {
        Settings.shared.textModel(for: kind) ?? Settings.shared.model(for: kind)
    }
}
