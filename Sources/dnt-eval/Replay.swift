import ArgumentParser
import DoNotTypeCore
import Foundation

/// Re-runs recordings the user actually made, across several backends, side by side.
///
/// Every other harness here runs fixture audio: eight synthesized phrases and seven extracts of a
/// recorded talk. Those measure what was chosen to be measured, which is the point of a fixture and
/// also its limit — none of them is the user's voice, their microphone, their vocabulary, or the
/// screen they were looking at. A backend can win the near-miss suite and still be wrong about the
/// words this particular person says every day.
///
/// The history already holds all of it. `keepAudio` stores the recording, `context` stores what was
/// on screen, and `latencySeconds` stores what the wait actually was — so a comparison against real
/// dictations needs no new capture path, only something that reads them back and re-sends them.
///
/// This is a debugging and evaluation tool, not a product feature: it re-sends recordings and screen
/// contents to every backend named, which costs money and puts that text in front of providers the
/// user did not choose for it. Nothing calls it but a person at a terminal.
struct Replay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "replay",
        abstract: "Re-run recorded dictations across several backends and compare them.",
        discussion: """
            Needs recordings: turn on Settings → History → "Keep audio" in the app, dictate a few \
            times, then run this. Without it the history keeps the transcript and the screen \
            context but discards the audio, and there is nothing to re-send.

            Backends are `provider[:model]`, comma separated — `xai` uses that provider's default \
            model, `google:gemini-3.5-flash` names one.
            """)

    @Option(
        name: .long,
        help: "Backends to compare, as provider[:model], comma separated.")
    var backends: String = "google:gemini-3.5-flash,google:gemini-3-flash-preview,xai"

    @Option(name: .long, help: "How many of the most recent recordings to replay.")
    var limit: Int = 5

    @Option(name: .long, help: "Replay one entry by ID prefix instead of the most recent.")
    var id: String?

    @Option(name: .long, help: "Runs per backend per recording. Above 1 the table reports a median.")
    var trials: Int = 1

    @Flag(
        name: .long,
        help: "Send no screen context, to see what grounding is worth on the user's own audio.")
    var noContext = false

    @Option(name: .long, help: "Fidelity: raw, light, or tidy.")
    var fidelity: String = Fidelity.default.rawValue

    @Option(name: .long, help: "Path to the prompt/ directory.")
    var prompt: String?

    @Option(name: .long, help: "Write the full comparison — every transcript — here as JSON.")
    var json: String?

    @Flag(name: .long, help: "Print the transcripts. On by default; --no-transcripts for the table alone.")
    var noTranscripts = false

    /// One backend's answer to one recording.
    struct Answer {
        var backend: String
        var seconds: [Double] = []
        var text = ""
        var error: String?
    }

    mutating func run() async throws {
        let store = HistoryStore(directory: HistoryStore.defaultDirectory())
        let specs = try parseBackends()
        let resolvedFidelity = try resolve(fidelity)
        let instruction = try systemInstruction(resolvedFidelity)

        let recordings = try await select(from: store)
        print(
            "\(recordings.count) recording(s) · \(specs.count) backends · \(trials) trial(s) each · "
                + "\(noContext ? "no screen context" : "recorded screen context")\n")

        var byBackend: [String: [Answer]] = [:]
        var report: [[String: Any]] = []

        for record in recordings {
            let audio = try await store.audioFile(for: record)
            printHeader(record, audio: audio)

            var answers: [Answer] = []
            for spec in specs {
                var answer = Answer(backend: spec.label)
                let runner = try makeRunner(spec, instruction: instruction, fidelity: resolvedFidelity)
                for _ in 0..<trials {
                    let started = Date()
                    do {
                        let result = try await runner.transcribe(
                            audio: audio, context: noContext ? nil : record.context)
                        answer.seconds.append(Date().timeIntervalSince(started))
                        answer.text = result.transcript.transcript
                    } catch {
                        // Uncut, and it does not abort the other backends: one dead key should not
                        // cost the run every comparison it was going to produce.
                        answer.error = error.localizedDescription
                    }
                }
                answers.append(answer)
                byBackend[spec.label, default: []].append(answer)
                printAnswer(answer, dictated: record.text)
            }
            print("")

            report.append([
                "id": record.id.uuidString,
                "createdAt": ISO8601DateFormatter().string(from: record.createdAt),
                "app": record.appName ?? "",
                "windowTitle": record.windowTitle ?? "",
                "audioSeconds": record.durationSeconds,
                "dictatedBy": "\(record.provider)/\(record.model)",
                "dictatedText": record.text,
                "dictatedSeconds": record.requestSeconds ?? record.latencySeconds ?? 0,
                "answers": answers.map {
                    [
                        "backend": $0.backend, "text": $0.text, "seconds": $0.seconds,
                        "error": $0.error ?? "",
                    ]
                },
            ])
        }

        summarise(specs.map(\.label), byBackend: byBackend, recordings: recordings)

        if let json {
            let data = try JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: json))
            print("\nfull transcripts → \(json)")
        }
    }

    // MARK: - Selection

    private func select(from store: HistoryStore) async throws -> [DictationRecord] {
        let withAudio = await store.all().filter { $0.audioFileName != nil }

        guard !withAudio.isEmpty else {
            let total = await store.all().count
            throw ValidationError(
                """
                No recording in the history has audio to replay\(total == 0 ? "" : " (\(total) entries, all audio discarded)").

                Turn on Settings → History → "Keep audio" in the app, dictate a few times, and run
                this again. Audio is off by default because it is the most sensitive thing this
                app touches; nothing here can reconstruct a recording that was never kept.
                """)
        }

        guard let id else { return Array(withAudio.prefix(limit)) }
        let matches = withAudio.filter { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }
        guard !matches.isEmpty else {
            throw ValidationError("No recording with audio starts with '\(id)'.")
        }
        return matches
    }

    // MARK: - Backends

    private struct Spec {
        var kind: ProviderKind
        var model: String
        var label: String
    }

    private func parseBackends() throws -> [Spec] {
        try backends.split(separator: ",").map { entry in
            let parts = entry.trimmingCharacters(in: .whitespaces).split(
                separator: ":", maxSplits: 1)
            let name = String(parts[0])
            guard let kind = ProviderKind(persistedValue: name) else {
                throw ValidationError(
                    "Unknown provider '\(name)'. Options: "
                        + ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))
            }
            let model = parts.count > 1 ? String(parts[1]) : kind.defaultModel
            return Spec(kind: kind, model: model, label: "\(kind.rawValue):\(model)")
        }
    }

    private func makeRunner(
        _ spec: Spec, instruction: String, fidelity: Fidelity
    ) throws -> EvalRunner {
        EvalRunner(
            provider: try ProviderFactory.make(spec.kind),
            model: spec.model,
            systemInstruction: instruction,
            fidelity: fidelity)
    }

    private func resolve(_ raw: String) throws -> Fidelity {
        guard let value = Fidelity(rawValue: raw.lowercased()) else {
            throw ValidationError(
                "Unknown fidelity '\(raw)'. Options: "
                    + Fidelity.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return value
    }

    private func systemInstruction(_ fidelity: Fidelity) throws -> String {
        let url = prompt.map { URL(fileURLWithPath: $0) } ?? PromptBuilder.findPromptDirectory()
        guard let url else {
            throw ValidationError("Could not find the prompt/ directory — pass --prompt.")
        }
        return try PromptBuilder(directory: url).systemInstruction(fidelity: fidelity)
    }

    // MARK: - Output

    private func printHeader(_ record: DictationRecord, audio: AudioFile) {
        let when = DateFormatter.localizedString(
            from: record.createdAt, dateStyle: .short, timeStyle: .short)
        var where_ = record.appName ?? "unknown app"
        if let title = record.windowTitle, !title.isEmpty { where_ += " · \(title)" }

        print("──────────────────────────────────────────────────────────────────────────────")
        // Measured from the file about to be sent, not read off the record: `durationSeconds` was
        // stored as 0 by every build before the JUNK-chunk fix, and a replay should describe the
        // audio it is actually replaying anyway.
        let seconds = audio.durationSeconds ?? record.durationSeconds
        print(
            "\(String(record.id.uuidString.prefix(8)))  \(when)  \(where_)  "
                + String(format: "%.1f s audio", seconds))

        // What the context actually was, because "grounded" with an empty screen is not grounded.
        if let context = record.context, !noContext {
            let visible = context.visibleText?.count ?? 0
            let caret = context.textBeforeCaret?.count ?? 0
            print("  context      \(visible) chars visible · \(caret) before caret")
        } else {
            print("  context      none sent")
        }

        let dictatedSeconds = record.requestSeconds ?? record.latencySeconds
        let timing = dictatedSeconds.map { String(format: "%.2f s", $0) } ?? "not recorded"
        print("  as dictated  \(record.provider)/\(record.model)  \(timing)")
        if !noTranscripts { print("    \(oneLine(record.text))") }
    }

    private func printAnswer(_ answer: Answer, dictated: String) {
        if let error = answer.error, answer.seconds.isEmpty {
            print("  \(answer.backend.padded(30))  failed: \(error)")
            return
        }
        let seconds = answer.seconds.sorted()
        let median = seconds[seconds.count / 2]
        let spread = seconds.count > 1
            ? String(format: " (%.2f–%.2f)", seconds.first ?? 0, seconds.last ?? 0) : ""
        let same = normalise(answer.text) == normalise(dictated) ? "  ≡ as dictated" : ""
        print("  \(answer.backend.padded(30))  " + String(format: "%.2f s", median) + spread + same)
        if !noTranscripts { print("    \(oneLine(answer.text))") }
    }

    private func summarise(
        _ labels: [String], byBackend: [String: [Answer]], recordings: [DictationRecord]
    ) {
        print("══════════════════════════════════════════════════════════════════════════════")
        print("\("backend".padded(30)) \("n".padded(4)) \("min".padded(8)) \("med".padded(8)) "
            + "\("max".padded(8)) \("chars".padded(7)) differs from dictated")

        for label in labels {
            let answers = byBackend[label] ?? []
            let seconds = answers.flatMap(\.seconds).sorted()
            guard !seconds.isEmpty else {
                print("\(label.padded(30)) \("0".padded(4)) every trial failed")
                continue
            }
            let ok = answers.filter { !$0.text.isEmpty }
            let differs = zip(ok, recordings).filter {
                normalise($0.0.text) != normalise($0.1.text)
            }.count
            let chars = ok.isEmpty ? 0 : ok.map(\.text.count).reduce(0, +) / ok.count

            print(
                label.padded(30) + " "
                    + "\(seconds.count)".padded(4) + " "
                    + String(format: "%.2f s", seconds.first ?? 0).padded(8) + " "
                    + String(format: "%.2f s", seconds[seconds.count / 2]).padded(8) + " "
                    + String(format: "%.2f s", seconds.last ?? 0).padded(8) + " "
                    + "\(chars)".padded(7) + " \(differs)/\(ok.count)")
        }

        print(
            """

            "differs from dictated" counts backends whose text is not identical to what the app \
            delivered at the time, ignoring case, spacing and punctuation. It is a disagreement \
            count, not an error count: the recorded transcript is another model's output, not a \
            golden. Read the transcripts to see who was right.
            """)
    }

    private func oneLine(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }

    /// Case, punctuation and spacing removed: two backends that heard the same words should not
    /// count as disagreeing because one of them wrote a comma.
    private func normalise(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension String {
    fileprivate func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
