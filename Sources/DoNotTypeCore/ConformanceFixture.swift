import Foundation

/// The shared fixture set behind the cross-platform encoder check.
///
/// `ContextEncoder` exists four times — Swift, Kotlin, C#, and Swift again on iOS — and every port
/// has to produce byte-identical request parts. Drift here would be silent: grounding would simply
/// work slightly differently on one platform, and the near-miss numbers measured on macOS would
/// stop describing what an Android user gets. Nothing else in the project would notice.
///
/// The fixtures and the expected output live in `eval/conformance/` as plain JSON so all four
/// suites read the same bytes rather than four copies that can drift apart on their own.
public enum ConformanceFixture {
    public struct Case: Codable, Sendable {
        public var id: String
        /// Why this case exists. Carried through to the golden file so a failure explains itself.
        public var why: String

        public var appName: String?
        public var windowTitle: String?
        public var browserUrl: String?
        public var role: String?
        public var isEditable: Bool?
        public var visibleText: String?
        public var textBeforeCaret: String?
        public var textAfterCaret: String?
        public var selectedText: String?
        public var screenshotBase64: String?
        /// Generates long text without putting 25 kB of it in the fixture file.
        public var visibleTextRepeat: Repeat?

        public struct Repeat: Codable, Sendable {
            public var line: String
            public var count: Int
        }

        public var context: ScreenContext {
            ScreenContext(
                appName: appName,
                windowTitle: windowTitle,
                browserURL: browserUrl,
                role: role,
                isEditable: isEditable,
                visibleText: resolvedVisibleText,
                textBeforeCaret: textBeforeCaret,
                textAfterCaret: textAfterCaret,
                selectedText: selectedText,
                screenshotPNG: screenshotBase64.flatMap { Data(base64Encoded: $0) })
        }

        var resolvedVisibleText: String? {
            guard let visibleTextRepeat else { return visibleText }
            return (1...visibleTextRepeat.count)
                .map { visibleTextRepeat.line.replacingOccurrences(of: "%d", with: "\($0)") }
                .joined()
        }
    }

    /// One encoded part, in a form that survives JSON and comparison across four languages.
    ///
    /// Image bytes are recorded as a length rather than inlined: what matters is that every port
    /// emits the image in the same position with the same type, and a base64 blob repeated in the
    /// golden file would obscure the text being checked.
    public struct EncodedPart: Codable, Sendable, Equatable {
        public var type: String
        public var text: String?
        public var mimeType: String?
        public var bytes: Int?

        public init(_ part: InputPart) {
            switch part {
            case .text(let value):
                type = "text"
                text = value
            case .image(let data, let mime):
                type = "image"
                mimeType = mime
                bytes = data.count
            case .audio(let data, let mime):
                type = "audio"
                mimeType = mime
                bytes = data.count
            case .remoteAudio(let uri, let mime):
                type = "remoteAudio"
                text = uri
                mimeType = mime
            }
        }
    }

    public struct Expectation: Codable, Sendable, Equatable {
        public var id: String
        public var why: String
        public var parts: [EncodedPart]
    }

    public static func loadCases(from url: URL) throws -> [Case] {
        try JSONDecoder().decode([Case].self, from: try Data(contentsOf: url))
    }

    public static func loadExpectations(from url: URL) throws -> [Expectation] {
        try JSONDecoder().decode([Expectation].self, from: try Data(contentsOf: url))
    }

    /// Runs every fixture through the real encoder. This is the reference output the other ports
    /// are checked against.
    public static func encode(_ cases: [Case], with encoder: ContextEncoder = ContextEncoder())
        -> [Expectation]
    {
        cases.map { testCase in
            Expectation(
                id: testCase.id, why: testCase.why,
                parts: encoder.encode(testCase.context).map(EncodedPart.init))
        }
    }

    public static func write(_ expectations: [Expectation], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(expectations).write(to: url)
    }

    /// Locates `eval/conformance/`, walking up from the working directory so the tests run from
    /// wherever a given toolchain decides to put them.
    public static func directory(startingAt start: URL? = nil) -> URL? {
        var directory = start ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("eval/conformance/contexts.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.deletingLastPathComponent()
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}
