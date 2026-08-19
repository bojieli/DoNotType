import Foundation

/// One cheap round trip that answers "will this key work when it matters?".
///
/// It exists because the alternative is finding out mid-dictation: the key is only read when the
/// user has already spoken, so a wrong or absent one surfaced as a failed recording rather than as
/// a setting that needed fixing. Asking at launch and after every edit turns that into a question
/// answered while nothing is at stake.
///
/// The probe deliberately distinguishes *rejected* from *no answer*. A 401 means the user has to do
/// something; a timeout on a train means nothing at all, and reporting the second as the first
/// would train people to ignore both.
///
/// It answers a second question as well: whether the audio arrives. Every probe is a recording, so
/// an endpoint that cannot take one — a text-only relay, a `vllm serve` in front of a text-only
/// checkpoint — is rejected here rather than discovered mid-dictation. The limit worth knowing is
/// that a provider reporting no usage at all still passes: `assertAudioWasProcessed` can only call
/// a *reported* zero a dropped recording, and silence about it stays unprovable either way.
public enum ProviderProbe {
    public enum Outcome: Sendable, Equatable {
        /// The provider answered and the key worked.
        case accepted
        /// The provider answered and something about this configuration has to change.
        case rejected(String)
        /// No usable answer — offline, timed out, or the provider itself is unwell. Says nothing
        /// about the key.
        case inconclusive(String)
    }

    /// - Parameter model: only used by model backends; recognition endpoints ignore it.
    public static func check(
        _ provider: any TranscriptionProvider, model: String
    ) async -> Outcome {
        // Audio, for every backend. Recognition endpoints always got silence, because they reject
        // a text-only request by design; model backends got text, and that turned out to be the
        // one thing this check could not afford to skip. "OpenAI-compatible" is a claim about the
        // request shape, so a relay or a text-only checkpoint answers the text probe perfectly and
        // then has nowhere to put a recording — which the user found out mid-dictation, from a
        // transcript the model invented. Probing with the same shape a dictation uses moves that
        // discovery to the settings window, where it costs nothing.
        //
        // A quarter second is deliberate rather than merely cheap: it is
        // `SpeechActivity.minimumSpeechMilliseconds`, the shortest audio this app will ever send
        // for real. Anything a provider does to this clip — including billing zero audio tokens
        // for it, which is how a dropped recording is detected — it would do to a real dictation.
        let parts: [InputPart] = [.audio(data: silentProbeWAV, mimeType: "audio/wav")]

        do {
            _ = try await provider.transcribe(
                TranscriptionRequest(
                    model: model,
                    systemInstruction: "You are a transcription engine.",
                    parts: parts))
            return .accepted
        } catch ProviderError.emptyOutput {
            // Silence transcribes to nothing, which is the correct answer and proves the round
            // trip worked.
            return .accepted
        } catch {
            // The same triage the dictation path uses, so a key check and a failed dictation never
            // disagree about whether the user has to act. `isOnline: true` because being offline
            // is exactly the case this must report as inconclusive rather than as a bad key.
            let advice = FailureAdvice.describe(error, isOnline: true)

            // `needsUserAction` alone is not the whole question here. A plain 4xx is deliberately
            // *not* the user's to act on during a dictation — nothing in Settings fixes a request
            // this app built wrong — so it is triaged as "worth reporting". The probe builds a
            // fixed, minimal request, and that reasoning inverts: if this one is refused, what is
            // wrong is the configuration it was sent with, and the endpoint field is where it gets
            // fixed. A text-only relay answering "input_audio is not supported" arrives exactly
            // this way, and reporting it as "could not ask" would hide the one answer the check
            // exists to give. Retryability is the honest discriminator — advice that says retrying
            // will not help is advice about a setting, not about the network.
            return advice.needsUserAction || !advice.isRetryable
                ? .rejected(advice.message)
                : .inconclusive(error.localizedDescription)
        }
    }

    /// A quarter-second of 16 kHz mono silence, built rather than shipped as a fixture so the
    /// bundle does not carry a resource used by one check.
    static let silentProbeWAV: Data = {
        let sampleRate = 16_000
        let samples = sampleRate / 4
        let dataBytes = samples * 2

        var wav = Data()
        func append(_ string: String) { wav.append(Data(string.utf8)) }
        func append(u32 value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        func append(u16 value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }

        append("RIFF")
        append(u32: UInt32(36 + dataBytes))
        append("WAVEfmt ")
        append(u32: 16)                                  // PCM header length
        append(u16: 1)                                   // PCM
        append(u16: 1)                                   // mono
        append(u32: UInt32(sampleRate))
        append(u32: UInt32(sampleRate * 2))              // byte rate
        append(u16: 2)                                   // block align
        append(u16: 16)                                  // bits per sample
        append("data")
        append(u32: UInt32(dataBytes))
        wav.append(Data(repeating: 0, count: dataBytes))
        return wav
    }()
}
