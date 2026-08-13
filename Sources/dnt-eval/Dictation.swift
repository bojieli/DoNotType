import ArgumentParser
import DoNotTypeCore
import Foundation

/// Runs the ordinary-dictation corpus and reports what can be measured without ground truth.
///
/// The near-miss suite scores against known-correct text, which is only possible because those
/// cases are short, synthetic or hand-verified. This corpus is 38 minutes of real speech with no
/// transcript, and machine-generating one would make every number circular — the "truth" would
/// come from the same class of system being measured.
///
/// Three things are still measurable, and they happen to be the three that decide a default:
///
/// 1. **Latency against clip length.** The number the user feels, on the distribution they
///    actually dictate. This needs no ground truth at all.
/// 2. **Failure rate.** Empty transcripts, errors, dropped audio. A backend that silently returns
///    nothing on 5% of clips is disqualified regardless of how it scores when it works.
/// 3. **Cross-backend disagreement.** Where independent backends produce the same words they are
///    probably right; where they diverge, one of them is wrong. That does not say *which*, so it
///    is reported as a review queue rather than a score — the shortlist of clips a human should
///    actually listen to, instead of all 100.
struct Dictation: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Latency, failure rate and cross-backend agreement on ordinary speech.")

    @Option(name: .long, help: "Corpus directory built by eval/build-dictation-corpus.py.")
    var corpus: String = "eval/dictation"

    @Option(name: .long, help: "Comma-separated backends to compare.")
    var providers: String = "xai,deepgram,mistral"

    @Option(name: .long, help: "Model override, applied to every provider. Rarely useful.")
    var model: String?

    @Option(name: .long, help: "Fidelity to request.")
    var fidelity: String = Fidelity.default.rawValue

    @Option(name: .long, help: "Only the first N clips, for a smoke run.")
    var limit: Int?

    @Option(name: .long, help: "Write the full per-clip result here as JSON.")
    var output: String?

    struct Entry: Decodable {
        var id: String
        var audio: String
        var seconds: Int
        var source: String
    }

    struct Manifest: Decodable {
        var clips: Int
        var entries: [Entry]
    }

    struct Outcome {
        var provider: String
        var clip: String
        var seconds: Int
        var latency: Double
        var text: String
        var language: String
        var error: String?
    }

    mutating func run() async throws {
        let root = URL(fileURLWithPath: corpus)
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw ValidationError(
                "No corpus at \(manifestURL.path). Build one with eval/build-dictation-corpus.py")
        }
        var entries = try JSONDecoder().decode(Manifest.self, from: data).entries
        if let limit { entries = Array(entries.prefix(limit)) }

        let kinds = try providers.split(separator: ",").map { name -> ProviderKind in
            guard let kind = ProviderKind(rawValue: name.trimmingCharacters(in: .whitespaces))
            else { throw ValidationError("Unknown provider '\(name)'") }
            return kind
        }
        guard let requested = Fidelity(rawValue: fidelity) else {
            throw ValidationError("Unknown fidelity '\(fidelity)'")
        }

        let instruction = try PromptBuilder(
            contentsOf: PromptBuilder.findPromptFile()
                ?? URL(fileURLWithPath: "PROMPT.md")).systemInstruction(fidelity: requested)

        print("ordinary-dictation corpus · \(entries.count) clips · "
            + "\(entries.reduce(0) { $0 + $1.seconds })s of speech")
        print("providers: \(kinds.map(\.rawValue).joined(separator: ", "))\n")

        var outcomes: [Outcome] = []
        for kind in kinds {
            let provider: any TranscriptionProvider
            do {
                provider = try ProviderFactory.make(kind)
            } catch {
                print("\(kind.rawValue): skipped — \(error.localizedDescription)\n")
                continue
            }
            let service = TranscriptionService(
                provider: provider, model: model ?? kind.defaultModel,
                systemInstruction: instruction, fidelity: requested)

            print("\(kind.rawValue) …", terminator: "")
            fflush(stdout)

            for entry in entries {
                let url = root.appendingPathComponent(entry.audio)
                guard let audio = try? AudioFile(contentsOf: url) else { continue }

                let start = Date()
                do {
                    // The product path, chunker included: a two-minute dictation is split and
                    // stitched in the app, so measuring a single request would measure something
                    // no user experiences.
                    let result = try await service.transcribeLong(audio: audio, context: nil)
                    outcomes.append(Outcome(
                        provider: kind.rawValue, clip: entry.id, seconds: entry.seconds,
                        latency: Date().timeIntervalSince(start),
                        text: result.transcript.transcript,
                        language: result.transcript.language, error: nil))
                } catch {
                    outcomes.append(Outcome(
                        provider: kind.rawValue, clip: entry.id, seconds: entry.seconds,
                        latency: Date().timeIntervalSince(start), text: "",
                        language: "", error: error.localizedDescription))
                }
            }
            print(" done")
        }

        print()
        reportLatency(outcomes)
        reportFailures(outcomes)
        reportAgreement(outcomes, entries: entries)
        reportLanguages(outcomes)

        if let output {
            let rows = outcomes.map {
                [
                    "provider": $0.provider, "clip": $0.clip, "seconds": "\($0.seconds)",
                    "latency": String(format: "%.3f", $0.latency),
                    "chars": "\($0.text.count)", "language": $0.language,
                    // The transcript itself, so agreement can be re-scored after a metric fix
                    // without re-running 38 minutes of audio through four paid backends. Written
                    // into the gitignored corpus directory: this is the user's own speech.
                    "text": $0.text,
                    "error": $0.error ?? "",
                ]
            }
            let json = try JSONSerialization.data(
                withJSONObject: ["results": rows], options: [.prettyPrinted, .sortedKeys])
            try json.write(to: URL(fileURLWithPath: output))
            print("\nper-clip results → \(output)")
        }
    }

    // MARK: - Reports

    /// The number a user feels, split by how long they spoke.
    private func reportLatency(_ outcomes: [Outcome]) {
        let providers = orderedProviders(outcomes)
        let buckets = Set(outcomes.map(\.seconds)).sorted()

        print("latency, seconds — median (p95)")
        print("clip   " + providers.map { $0.padding(toLength: 18, withPad: " ", startingAt: 0) }
            .joined())

        for bucket in buckets {
            var row = String(format: "%4ds  ", bucket)
            for provider in providers {
                let values = outcomes
                    .filter { $0.provider == provider && $0.seconds == bucket && $0.error == nil }
                    .map(\.latency).sorted()
                row += (values.isEmpty
                    ? "—"
                    : String(format: "%.2f (%.2f)", percentile(values, 0.5), percentile(values, 0.95)))
                    .padding(toLength: 18, withPad: " ", startingAt: 0)
            }
            print(row)
        }

        var overall = "all   "
        for provider in providers {
            let values = outcomes.filter { $0.provider == provider && $0.error == nil }
                .map(\.latency).sorted()
            overall += (values.isEmpty
                ? "—"
                : String(format: "%.2f (%.2f)", percentile(values, 0.5), percentile(values, 0.95)))
                .padding(toLength: 18, withPad: " ", startingAt: 0)
        }
        print(overall)

        // Latency per second spoken is the fairer cross-length comparison: a backend that is fast
        // on three-second clips and superlinear on two-minute ones is a different product.
        var ratio = "×real "
        for provider in providers {
            let rows = outcomes.filter { $0.provider == provider && $0.error == nil }
            let spoken = rows.reduce(0.0) { $0 + Double($1.seconds) }
            let spent = rows.reduce(0.0) { $0 + $1.latency }
            ratio += (spoken == 0 ? "—" : String(format: "%.3f× audio", spent / spoken))
                .padding(toLength: 18, withPad: " ", startingAt: 0)
        }
        print(ratio)
    }

    private func reportFailures(_ outcomes: [Outcome]) {
        print("\nfailures")
        for provider in orderedProviders(outcomes) {
            let rows = outcomes.filter { $0.provider == provider }
            let errored = rows.filter { $0.error != nil }
            let empty = rows.filter { $0.error == nil && $0.transcriptIsEmpty }
            print("  \(provider.padding(toLength: 12, withPad: " ", startingAt: 0))"
                + "\(errored.count) errored, \(empty.count) empty of \(rows.count)")
            // One example is enough to act on; a wall of identical timeouts is not.
            if let first = errored.first {
                print("      e.g. \(first.clip): \(first.error ?? "")".prefix(150))
            }
        }
    }

    /// Where independent backends disagree, at least one is wrong.
    ///
    /// Deliberately not a score. Agreement says nothing about which backend is right, and two
    /// recognisers sharing a training corpus can agree on the same mistake. It is a *sampling*
    /// tool: it turns "listen to 100 clips" into "listen to the 10 where they diverged".
    private func reportAgreement(_ outcomes: [Outcome], entries: [Entry]) {
        let providers = orderedProviders(outcomes)
        guard providers.count >= 2 else { return }

        var scored: [(clip: String, seconds: Int, agreement: Double)] = []
        for entry in entries {
            let texts = providers.compactMap { provider in
                outcomes.first { $0.provider == provider && $0.clip == entry.id && $0.error == nil }?
                    .text
            }
            guard texts.count >= 2 else { continue }

            // Mean pairwise word-level similarity across every pair of backends.
            var totals: [Double] = []
            for i in texts.indices {
                for j in texts.indices where j > i {
                    totals.append(Self.similarity(texts[i], texts[j]))
                }
            }
            guard !totals.isEmpty else { continue }
            scored.append((entry.id, entry.seconds,
                totals.reduce(0, +) / Double(totals.count)))
        }
        guard !scored.isEmpty else { return }

        let mean = scored.reduce(0.0) { $0 + $1.agreement } / Double(scored.count)
        print(String(format: "\nagreement  mean %.1f%% word overlap across %d clips",
            mean * 100, scored.count))

        let worst = scored.sorted { $0.agreement < $1.agreement }.prefix(10)
        print("  review queue — lowest agreement, listen to these first:")
        for row in worst {
            print(String(format: "    %-16s %4ds  %.0f%%", (row.clip as NSString).utf8String!,
                row.seconds, row.agreement * 100))
        }
        print("  Low agreement means the backends differ, not that any one is wrong. Verify by ear")
        print("  before treating a clip as a failure of a particular provider.")
    }

    /// What language this corpus is actually in, which decides more than any score does: a
    /// backend that cannot transcribe the user's language is disqualified however fast it is.
    private func reportLanguages(_ outcomes: [Outcome]) {
        let reported = outcomes.filter { $0.error == nil && !$0.language.isEmpty }
        guard !reported.isEmpty else { return }

        var counts: [String: Int] = [:]
        for outcome in reported { counts[outcome.language, default: 0] += 1 }

        print("\ndetected language (as reported by the backends that report one)")
        for (language, count) in counts.sorted(by: { $0.value > $1.value }) {
            let share = 100.0 * Double(count) / Double(reported.count)
            print(String(format: "  %-6s %4d  %.0f%%", (language as NSString).utf8String!,
                count, share))
        }
    }

    // MARK: - Helpers

    /// Word-level overlap, order-insensitive within a multiset.
    ///
    /// Not an edit distance: recognisers legitimately differ on punctuation and casing, and an
    /// alignment-based score would punish that as heavily as a wrong word. This counts how much
    /// of the *vocabulary actually spoken* the two runs share, which is the question being asked.
    static func similarity(_ left: String, _ right: String) -> Double {
        let a = words(left), b = words(right)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        var counts: [String: Int] = [:]
        for word in a { counts[word, default: 0] += 1 }
        var shared = 0
        for word in b where (counts[word] ?? 0) > 0 {
            counts[word]! -= 1
            shared += 1
        }
        return 2.0 * Double(shared) / Double(a.count + b.count)
    }

    /// Splits Latin text on word boundaries and CJK text per character.
    ///
    /// The first version of this split only on non-alphanumerics, which is wrong for exactly the
    /// language this corpus is mostly in: Chinese is written without spaces, so an entire Mandarin
    /// sentence came back as a single token and two backends that differed by one character scored
    /// 0% overlap. That made the review queue rank clips by *language* rather than by
    /// disagreement, and it put 71% of the corpus at the top of it.
    static func words(_ text: String) -> [String] {
        var tokens: [String] = []
        var latin = ""

        func flush() {
            if !latin.isEmpty { tokens.append(latin); latin = "" }
        }

        for character in text.lowercased() {
            if character.isCJK {
                flush()
                tokens.append(String(character))
            } else if character.isLetter || character.isNumber {
                latin.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    private func orderedProviders(_ outcomes: [Outcome]) -> [String] {
        var seen: [String] = []
        for outcome in outcomes where !seen.contains(outcome.provider) {
            seen.append(outcome.provider)
        }
        return seen
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[index]
    }
}

extension Dictation.Outcome {
    var transcriptIsEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension Character {
    /// CJK ideographs plus the kana blocks — the scripts written without spaces, where a
    /// word-boundary split degenerates to one token per sentence.
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)      // hiragana, katakana
                || (0x3400...0x4DBF).contains(scalar.value)   // CJK extension A
                || (0x4E00...0x9FFF).contains(scalar.value)   // CJK unified ideographs
                || (0xF900...0xFAFF).contains(scalar.value)   // compatibility ideographs
        }
    }
}
