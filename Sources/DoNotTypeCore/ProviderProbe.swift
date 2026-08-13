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
        // A recognition backend rejects a text-only request by design, so probing one with the
        // text round trip would report a working key as broken. It gets a fraction of a second of
        // silence instead — enough to exercise auth, the URL and the response shape, which is all
        // this check claims to cover.
        let parts: [InputPart] =
            provider.grounding(forModel: model) == .multimodal
            ? [.text("Pretend the audio said: ok. Transcribe it.")]
            : [.audio(data: silentProbeWAV, mimeType: "audio/wav")]

        do {
            _ = try await provider.transcribe(
                TranscriptionRequest(
                    model: model,
                    systemInstruction: "You are a transcription engine.",
                    parts: parts))
            return .accepted
        } catch ProviderError.emptyOutput {
            // Silence transcribes to nothing, which is the correct answer and proves the round
            // trip worked. Only the recognition path can reach this, since the text probe always
            // produces output.
            return .accepted
        } catch {
            // The same triage the dictation path uses, so a key check and a failed dictation never
            // disagree about whether the user has to act. `isOnline: true` because being offline
            // is exactly the case this must report as inconclusive rather than as a bad key.
            let advice = FailureAdvice.describe(error, isOnline: true)
            return advice.needsUserAction
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
