import ArgumentParser
import DoNotTypeCore
import Foundation

/// Replays retained hotkey dictations through several backends without pretending one answer is
/// ground truth.
///
/// The history row is the unit of comparison because it keeps the two inputs that matter together:
/// the recording and the screen context captured for that recording. The exact assembled prompt,
/// encoded context parts and request knobs are written into the manifest before the first paid
/// request, so the resulting numbers remain attributable if the product prompt later changes.
struct HistoryBenchmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history-benchmark",
        abstract: "Compare models on retained hotkey audio and its original screen context.")

    @Option(
        name: .long,
        help: "History directory containing history.json and audio/. Defaults to the app store.")
    var history: String?

    @Option(
        name: .long,
        help: "Shipped prompt/ directory. User overrides beside history.json still take priority.")
    var prompt: String?

    @Option(
        name: .shortAndLong,
        help: "Final JSON result. A manifest and resumable JSONL journal are written beside it.")
    var output = "eval/results/hotkey-model-benchmark-2026-08-18.json"

    @Option(name: .long, help: "Top-level transcriptions in flight. Each model remains sequential.")
    var concurrency = 3

    @Option(name: .long, help: "Only the newest N retained recordings; omit for all.")
    var limit: Int?

    @Flag(name: .long, help: "Discard this benchmark's generated manifest/journal and start over.")
    var restart = false

    private static let requestedModels = [
        ModelSpec(provider: .google, model: "gemini-3-flash-preview"),
        ModelSpec(provider: .google, model: "gemini-3.5-flash"),
        ModelSpec(provider: .google, model: "gemini-3.6-flash"),
        ModelSpec(provider: .google, model: "gemini-3.7-flash"),
        ModelSpec(provider: .xai, model: "grok-stt"),
    ]

    mutating func run() async throws {
        guard concurrency > 0 && concurrency <= Self.requestedModels.count else {
            throw ValidationError("--concurrency must be between 1 and 5.")
        }
        if let limit, limit <= 0 { throw ValidationError("--limit must be positive.") }

        let historyURL = URL(
            fileURLWithPath: history ?? HistoryStore.defaultDirectory().path,
            isDirectory: true).standardizedFileURL
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        let manifestURL = outputURL.appendingPathExtension("manifest.json")
        let journalURL = outputURL.appendingPathExtension("journal.jsonl")

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if restart {
            for url in [outputURL, manifestURL, journalURL]
                where FileManager.default.fileExists(atPath: url.path)
            {
                try FileManager.default.removeItem(at: url)
            }
        }

        let manifest: BenchmarkManifest
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try BenchmarkJSON.decoder.decode(
                BenchmarkManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.concurrency == concurrency else {
                throw ValidationError(
                    "This manifest was created with concurrency \(manifest.concurrency). "
                        + "Resume with --concurrency \(manifest.concurrency), or pass --restart.")
            }
            guard manifest.models.map(\.id) == Self.requestedModels.map(\.id) else {
                throw ValidationError(
                    "The benchmark model list changed since this manifest was created; pass --restart.")
            }
            print("resuming manifest · \(manifest.cases.count) recordings · \(manifest.models.count) models")
        } else {
            manifest = try await makeManifest(historyURL: historyURL)
            try BenchmarkJSON.encoder(pretty: true).encode(manifest).write(
                to: manifestURL, options: .atomic)
            print("manifest → \(manifestURL.path)")
        }

        let existing = try loadJournal(journalURL)
        let completed = Set(existing.map(\.key))
        let total = manifest.cases.count * manifest.models.count
        print(
            "hotkey history · \(manifest.cases.count) recordings · "
                + String(format: "%.1f", manifest.cases.reduce(0) { $0 + $1.audioSeconds } / 60)
                + " min audio · \(manifest.models.count) models")
        print("concurrency \(concurrency) globally · 1 per model · long clips split sequentially")
        print("already complete \(existing.count)/\(total)\n")

        let services = try makeServices(manifest: manifest)
        let permitPool = PermitPool(limit: concurrency)
        let sink = try ResultJournal(url: journalURL, existing: existing, total: total)
        let audioRoot = historyURL.appendingPathComponent("audio", isDirectory: true)

        await withTaskGroup(of: Void.self) { group in
            for (modelIndex, model) in manifest.models.enumerated() {
                let service = services[model.id]!
                // Rotate the starting clip by model. This avoids all providers reading the same
                // large WAV simultaneously while retaining the same case set for every model.
                let cases = Self.rotated(manifest.cases, by: modelIndex)
                group.addTask {
                    for benchmarkCase in cases {
                        let key = BenchmarkResult.key(
                            caseID: benchmarkCase.id, modelID: model.id)
                        if completed.contains(key) { continue }

                        await permitPool.acquire()
                        let row = await Self.transcribe(
                            benchmarkCase, with: model, service: service,
                            audioRoot: audioRoot)
                        await permitPool.release()

                        do {
                            try await sink.append(row)
                        } catch {
                            // A provider failure is data; an unwritable benchmark is not. Stop
                            // scheduling this model, and leave the valid journal resumable.
                            fputs("could not append benchmark journal: \(error)\n", stderr)
                            return
                        }
                    }
                }
            }
            await group.waitForAll()
        }

        let results = await sink.results()
        try await sink.close()
        let document = BenchmarkDocument(
            manifest: manifest,
            completedAt: results.count == total ? Date() : nil,
            results: Self.sorted(results, manifest: manifest),
            statistics: Self.statistics(
                results, models: manifest.models, cases: manifest.cases))
        try BenchmarkJSON.encoder(pretty: true).encode(document).write(
            to: outputURL, options: .atomic)

        print("\nJSON → \(outputURL.path)")
        Self.printStatistics(document.statistics)
        if results.count != total {
            print("\npartial run: \(results.count)/\(total) results; rerun the same command to resume")
            throw ExitCode.failure
        }
    }

    // MARK: - Manifest

    private func makeManifest(historyURL: URL) async throws -> BenchmarkManifest {
        let indexURL = historyURL.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: indexURL) else {
            throw ValidationError("No history index at \(indexURL.path).")
        }
        var records = try BenchmarkJSON.decoder.decode([DictationRecord].self, from: data)
            .filter { $0.audioFileName != nil && $0.context != nil }
        if let limit { records = Array(records.prefix(limit)) }
        guard !records.isEmpty else {
            throw ValidationError("History has no rows with both retained audio and context.")
        }

        let bundled = prompt.map { URL(fileURLWithPath: $0) }
            ?? PromptBuilder.findPromptDirectory()
        guard let bundled else {
            throw ValidationError("Could not find prompt/; pass --prompt.")
        }
        // This is the app's lookup rule: per-part user overrides beside history.json, falling back
        // to the shipped prompt. There are currently no overrides, but recording the resolved text
        // is what makes that fact durable rather than assumed.
        let builder = PromptStore(directory: historyURL).builder(bundled: bundled)
        let fidelity = records.first?.fidelity ?? .default
        guard records.allSatisfy({ $0.fidelity == fidelity }) else {
            throw ValidationError(
                "The retained rows contain multiple fidelity levels; split them into separate runs.")
        }
        let instruction = try builder.systemInstruction(fidelity: fidelity)
        let encoder = ContextEncoder()
        let audioRoot = historyURL.appendingPathComponent("audio", isDirectory: true)

        var cases: [BenchmarkCase] = []
        for record in records {
            guard let name = record.audioFileName, Self.safeAudioName(name),
                let context = record.context
            else { continue }
            let audioURL = audioRoot.appendingPathComponent(name)
            guard let audio = try? AudioFile(contentsOf: audioURL) else { continue }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size])
                as? NSNumber
            cases.append(BenchmarkCase(
                id: record.id.uuidString,
                createdAt: record.createdAt,
                audioFileName: name,
                audioBytes: bytes?.intValue ?? audio.data.count,
                audioSeconds: audio.durationSeconds ?? record.durationSeconds,
                context: context,
                encodedContext: encoder.encode(context).map(EncodedPart.init),
                original: OriginalResult(
                    provider: record.provider, model: record.model,
                    requestSeconds: record.requestSeconds,
                    text: record.text, language: "")))
        }

        let modelDescriptors = Self.requestedModels.map { spec in
            let grounding: String
            let readsPrompt: Bool
            let contextHandling: String
            let thinking: String?
            switch spec.provider {
            case .google:
                grounding = "multimodal"
                readsPrompt = true
                contextHandling = "Full encoded ScreenContext parts are sent before the audio."
                thinking = GeminiProvider.cheapestThinkingLevel(forModel: spec.model)
            case .xai:
                grounding = "keyterms"
                readsPrompt = false
                contextHandling = "No screen-derived keyterms are sent (keyterm biasing is off)."
                thinking = nil
            default:
                grounding = "none"
                readsPrompt = false
                contextHandling = "No screen context is accepted by this endpoint."
                thinking = nil
            }
            return ModelDescriptor(
                id: spec.id, provider: spec.provider.rawValue, model: spec.model,
                grounding: grounding, readsSystemInstruction: readsPrompt,
                contextHandling: contextHandling, thinkingLevel: thinking)
        }

        return BenchmarkManifest(
            schemaVersion: 1,
            benchmark: "retained-hotkey-transcription",
            startedAt: Date(),
            source: SourceMetadata(
                historyDirectory: historyURL.path,
                historyIndex: indexURL.path,
                selection: "Every newest-first history row with retained audio and stored context"
                    + (limit.map { ", limited to \($0)" } ?? "")),
            request: RequestMetadata(
                fidelity: fidelity.rawValue,
                promptDirectory: bundled.standardizedFileURL.path,
                systemInstruction: instruction,
                promptDigest: CassetteKey.digest(of: instruction),
                contextEncoder: "ContextEncoder.default",
                keytermBiasing: false,
                personalDictionary: [],
                attemptsPerChunk: 1,
                stallHedging: false,
                longClipChunkConcurrency: 1,
                structuredOutput: true,
                googleStore: false,
                notes: [
                    "The historical transcript is shown for comparison but is not golden truth.",
                    "Latency starts after WAV loading and ends after the complete parsed response.",
                    "Long recordings use the product chunker, with chunks sequential to preserve the global cap.",
                    "xAI /v1/stt cannot read the system instruction or labelled screen context.",
                ]),
            concurrency: concurrency,
            models: modelDescriptors,
            cases: cases)
    }

    private func makeServices(
        manifest: BenchmarkManifest
    ) throws -> [String: TranscriptionService] {
        var services: [String: TranscriptionService] = [:]
        guard let fidelity = Fidelity(rawValue: manifest.request.fidelity) else {
            throw ValidationError("Manifest has unknown fidelity \(manifest.request.fidelity).")
        }
        for spec in Self.requestedModels {
            let provider = try ProviderFactory.make(spec.provider)
            services[spec.id] = TranscriptionService(
                provider: provider,
                model: spec.model,
                systemInstruction: manifest.request.systemInstruction,
                fidelity: fidelity,
                keytermBiasing: false,
                personalDictionary: [],
                hedgeStalledRequests: false)
        }
        return services
    }

    // MARK: - Requests

    private static func transcribe(
        _ benchmarkCase: BenchmarkCase,
        with model: ModelDescriptor,
        service: TranscriptionService,
        audioRoot: URL
    ) async -> BenchmarkResult {
        let startedAt = Date()
        do {
            let audio = try AudioFile(
                contentsOf: audioRoot.appendingPathComponent(benchmarkCase.audioFileName))
            // Exactly one attempt. Retries and stall hedges select the faster of several draws and
            // would make this a reliability policy benchmark rather than a model latency one.
            let result = try await service.transcribeLong(
                audio: audio, context: benchmarkCase.context,
                attempts: 1, maxConcurrent: 1)
            return BenchmarkResult(
                caseID: benchmarkCase.id,
                modelID: model.id,
                provider: model.provider,
                model: model.model,
                startedAt: startedAt,
                latencySeconds: Date().timeIntervalSince(startedAt),
                status: .success,
                text: result.transcript.transcript,
                language: result.transcript.language,
                error: nil,
                chunks: result.chunkCount,
                usage: result.usage,
                suppression: result.suppressed == .kept ? nil : result.suppressed.summary)
        } catch {
            return BenchmarkResult(
                caseID: benchmarkCase.id,
                modelID: model.id,
                provider: model.provider,
                model: model.model,
                startedAt: startedAt,
                latencySeconds: Date().timeIntervalSince(startedAt),
                status: .failure,
                text: "",
                language: "",
                error: error.localizedDescription,
                chunks: 0,
                usage: TokenUsage(),
                suppression: nil)
        }
    }

    // MARK: - Journal and reports

    private func loadJournal(_ url: URL) throws -> [BenchmarkResult] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        var byKey: [String: BenchmarkResult] = [:]
        for (index, line) in text.split(separator: "\n").enumerated() {
            do {
                let row = try BenchmarkJSON.decoder.decode(
                    BenchmarkResult.self, from: Data(line.utf8))
                byKey[row.key] = row
            } catch {
                throw ValidationError(
                    "Unreadable journal line \(index + 1) in \(url.path): \(error.localizedDescription)")
            }
        }
        return Array(byKey.values)
    }

    private static func sorted(
        _ results: [BenchmarkResult], manifest: BenchmarkManifest
    ) -> [BenchmarkResult] {
        let caseOrder = Dictionary(
            uniqueKeysWithValues: manifest.cases.enumerated().map { ($1.id, $0) })
        let modelOrder = Dictionary(
            uniqueKeysWithValues: manifest.models.enumerated().map { ($1.id, $0) })
        return results.sorted {
            (caseOrder[$0.caseID] ?? .max, modelOrder[$0.modelID] ?? .max)
                < (caseOrder[$1.caseID] ?? .max, modelOrder[$1.modelID] ?? .max)
        }
    }

    private static func statistics(
        _ results: [BenchmarkResult], models: [ModelDescriptor], cases: [BenchmarkCase]
    ) -> [ModelStatistics] {
        let audioSeconds = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0.audioSeconds) })
        return models.map { model in
            let rows = results.filter { $0.modelID == model.id }
            let successful = rows.filter { $0.status == .success }
            let values = successful.map(\.latencySeconds).sorted()
            let totalAudio = successful.reduce(0.0) {
                $0 + (audioSeconds[$1.caseID] ?? 0)
            }
            let realTimeFactors = successful.compactMap { row -> Double? in
                guard let duration = audioSeconds[row.caseID], duration > 0 else { return nil }
                return row.latencySeconds / duration
            }.sorted()
            let mean = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            let variance: Double? = if let mean, !values.isEmpty {
                values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
            } else { nil }
            return ModelStatistics(
                modelID: model.id,
                attempted: rows.count,
                succeeded: successful.count,
                failed: rows.count - successful.count,
                successRate: rows.isEmpty ? nil : Double(successful.count) / Double(rows.count),
                minimumSeconds: values.first,
                maximumSeconds: values.last,
                meanSeconds: mean,
                medianSeconds: percentile(values, 0.50),
                p90Seconds: percentile(values, 0.90),
                p95Seconds: percentile(values, 0.95),
                p99Seconds: percentile(values, 0.99),
                standardDeviationSeconds: variance.map(sqrt),
                totalSeconds: values.reduce(0, +),
                totalChunks: successful.reduce(0) { $0 + $1.chunks },
                aggregateRealTimeFactor: totalAudio > 0
                    ? values.reduce(0, +) / totalAudio : nil,
                medianRealTimeFactor: percentile(realTimeFactors, 0.50))
        }
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    private static func printStatistics(_ stats: [ModelStatistics]) {
        print("\nlatency seconds — successful calls only")
        print("model".padding(toLength: 29, withPad: " ", startingAt: 0)
            + " ok       min    mean     med     p95     max      sd")
        for row in stats {
            func number(_ value: Double?) -> String {
                value.map { String(format: "%.2f", $0) } ?? "—"
            }
            func cell(_ value: Double?) -> String {
                number(value).padding(toLength: 8, withPad: " ", startingAt: 0)
            }
            let model = String(row.modelID.prefix(29))
            let success = "\(row.succeeded)/\(row.attempted)"
                .padding(toLength: 8, withPad: " ", startingAt: 0)
            print(
                model.padding(toLength: 29, withPad: " ", startingAt: 0)
                    + " " + success
                    + cell(row.minimumSeconds) + cell(row.meanSeconds)
                    + cell(row.medianSeconds) + cell(row.p95Seconds)
                    + cell(row.maximumSeconds) + cell(row.standardDeviationSeconds))
        }
    }

    private static func safeAudioName(_ name: String) -> Bool {
        !name.isEmpty && URL(fileURLWithPath: name).lastPathComponent == name
            && name.lowercased().hasSuffix(".wav")
    }

    private static func rotated<T>(_ values: [T], by offset: Int) -> [T] {
        guard !values.isEmpty else { return [] }
        let pivot = offset % values.count
        return Array(values[pivot...]) + Array(values[..<pivot])
    }
}

// MARK: - Schema

private struct ModelSpec: Sendable {
    var provider: ProviderKind
    var model: String
    var id: String { "\(provider.rawValue)/\(model)" }
}

private struct BenchmarkManifest: Codable, Sendable {
    var schemaVersion: Int
    var benchmark: String
    var startedAt: Date
    var source: SourceMetadata
    var request: RequestMetadata
    var concurrency: Int
    var models: [ModelDescriptor]
    var cases: [BenchmarkCase]
}

private struct SourceMetadata: Codable, Sendable {
    var historyDirectory: String
    var historyIndex: String
    var selection: String
}

private struct RequestMetadata: Codable, Sendable {
    var fidelity: String
    var promptDirectory: String
    var systemInstruction: String
    var promptDigest: String
    var contextEncoder: String
    var keytermBiasing: Bool
    var personalDictionary: [String]
    var attemptsPerChunk: Int
    var stallHedging: Bool
    var longClipChunkConcurrency: Int
    var structuredOutput: Bool
    var googleStore: Bool
    var notes: [String]
}

private struct ModelDescriptor: Codable, Sendable {
    var id: String
    var provider: String
    var model: String
    var grounding: String
    var readsSystemInstruction: Bool
    var contextHandling: String
    var thinkingLevel: String?
}

private struct BenchmarkCase: Codable, Sendable {
    var id: String
    var createdAt: Date
    var audioFileName: String
    var audioBytes: Int
    var audioSeconds: Double
    var context: ScreenContext
    var encodedContext: [EncodedPart]
    var original: OriginalResult
}

private struct EncodedPart: Codable, Sendable {
    var type: String
    var text: String?
    var mimeType: String?
    var data: Data?

    init(_ part: InputPart) {
        switch part {
        case .text(let value):
            type = "text"
            text = value
        case .image(let bytes, let mime):
            type = "image"
            mimeType = mime
            data = bytes
        case .audio(let bytes, let mime):
            type = "audio"
            mimeType = mime
            data = bytes
        }
    }
}

private struct OriginalResult: Codable, Sendable {
    var provider: String
    var model: String
    var requestSeconds: Double?
    var text: String
    var language: String
}

private struct BenchmarkResult: Codable, Sendable {
    enum Status: String, Codable, Sendable { case success, failure }

    var caseID: String
    var modelID: String
    var provider: String
    var model: String
    var startedAt: Date
    var latencySeconds: Double
    var status: Status
    var text: String
    var language: String
    var error: String?
    var chunks: Int
    var usage: TokenUsage
    var suppression: String?

    var key: String { Self.key(caseID: caseID, modelID: modelID) }
    static func key(caseID: String, modelID: String) -> String {
        "\(caseID)\u{1f}\(modelID)"
    }
}

private struct ModelStatistics: Codable, Sendable {
    var modelID: String
    var attempted: Int
    var succeeded: Int
    var failed: Int
    var successRate: Double?
    var minimumSeconds: Double?
    var maximumSeconds: Double?
    var meanSeconds: Double?
    var medianSeconds: Double?
    var p90Seconds: Double?
    var p95Seconds: Double?
    var p99Seconds: Double?
    var standardDeviationSeconds: Double?
    var totalSeconds: Double
    var totalChunks: Int
    var aggregateRealTimeFactor: Double?
    var medianRealTimeFactor: Double?
}

private struct BenchmarkDocument: Codable, Sendable {
    var schemaVersion: Int { manifest.schemaVersion }
    var benchmark: String { manifest.benchmark }
    var startedAt: Date { manifest.startedAt }
    var completedAt: Date?
    var source: SourceMetadata { manifest.source }
    var request: RequestMetadata { manifest.request }
    var concurrency: Int { manifest.concurrency }
    var models: [ModelDescriptor] { manifest.models }
    var cases: [BenchmarkCase] { manifest.cases }
    var results: [BenchmarkResult]
    var statistics: [ModelStatistics]

    private var manifest: BenchmarkManifest

    init(
        manifest: BenchmarkManifest, completedAt: Date?, results: [BenchmarkResult],
        statistics: [ModelStatistics]
    ) {
        self.manifest = manifest
        self.completedAt = completedAt
        self.results = results
        self.statistics = statistics
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, benchmark, startedAt, completedAt, source, request, concurrency
        case models, cases, results, statistics
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        let benchmark = try values.decode(String.self, forKey: .benchmark)
        let startedAt = try values.decode(Date.self, forKey: .startedAt)
        let source = try values.decode(SourceMetadata.self, forKey: .source)
        let request = try values.decode(RequestMetadata.self, forKey: .request)
        let concurrency = try values.decode(Int.self, forKey: .concurrency)
        let models = try values.decode([ModelDescriptor].self, forKey: .models)
        let cases = try values.decode([BenchmarkCase].self, forKey: .cases)
        manifest = BenchmarkManifest(
            schemaVersion: schemaVersion, benchmark: benchmark, startedAt: startedAt,
            source: source, request: request, concurrency: concurrency,
            models: models, cases: cases)
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
        results = try values.decode([BenchmarkResult].self, forKey: .results)
        statistics = try values.decode([ModelStatistics].self, forKey: .statistics)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(benchmark, forKey: .benchmark)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encodeIfPresent(completedAt, forKey: .completedAt)
        try values.encode(source, forKey: .source)
        try values.encode(request, forKey: .request)
        try values.encode(concurrency, forKey: .concurrency)
        try values.encode(models, forKey: .models)
        try values.encode(cases, forKey: .cases)
        try values.encode(results, forKey: .results)
        try values.encode(statistics, forKey: .statistics)
    }
}

private enum BenchmarkJSON {
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }
}

// MARK: - Bounded scheduling and durable output

private actor PermitPool {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private actor ResultJournal {
    private let handle: FileHandle
    private var rows: [BenchmarkResult]
    private let total: Int
    private var closed = false

    init(url: URL, existing: [BenchmarkResult], total: Int) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        rows = existing
        self.total = total
    }

    deinit { try? handle.close() }

    func append(_ row: BenchmarkResult) throws {
        var data = try BenchmarkJSON.encoder(pretty: false).encode(row)
        data.append(0x0a)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        rows.append(row)
        if rows.count % 10 == 0 || rows.count == total {
            print("\rcompleted \(rows.count)/\(total)", terminator: "")
            fflush(stdout)
        }
    }

    func results() -> [BenchmarkResult] { rows }

    func close() throws {
        guard !closed else { return }
        try handle.close()
        closed = true
    }
}
