import ArgumentParser
import DoNotTypeCore
import Foundation

/// Prints the keyterms a screen context would produce, without sending anything.
///
/// Exists for the same reason the app has a Context Inspector: a recognition backend is sent a
/// word list derived from the user's screen, and "you can read what it read" has to hold for that
/// channel too. Until this command existed the terms were the one part of a request nobody could
/// see — including whoever was writing the evaluation, which is how a benchmark gets reported
/// without anyone knowing what was actually in the biasing list.
struct KeytermsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keyterms",
        abstract: "Show the spelling hints a case's screen context would send.")

    @Argument(help: "A case JSON file, or a directory of them.")
    var path: String = "eval/nearmiss"

    @Option(name: .long, help: "Provider cap to apply. Deepgram and xAI both allow 100.")
    var maxTerms: Int = 100

    @Option(name: .long, help: "Longest single term the provider accepts.")
    var maxChars: Int = 50

    mutating func run() async throws {
        let url = URL(fileURLWithPath: path)
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true

        let cases: [(EvalCase, URL)] =
            isDirectory
            ? try EvalRunner.loadCases(in: url)
            : [(try JSONDecoder().decode(EvalCase.self, from: try Data(contentsOf: url)), url)]

        guard !cases.isEmpty else {
            throw ValidationError("No .json cases found in \(path)")
        }

        for (testCase, _) in cases {
            let terms = DoNotTypeCore.Keyterms.derive(
                from: testCase.context, maxTerms: maxTerms, maxCharsPerTerm: maxChars)

            print("\(testCase.id)  (\(terms.count))")
            if terms.isEmpty {
                print("    — nothing qualified; this case sends no hints at all")
            } else {
                print("    \(terms.joined(separator: ", "))")
            }

            // The guarantee is worth restating per case rather than trusting once: a digit here
            // would mean a version number on screen could overwrite a spoken one.
            if let offender = terms.first(where: { $0.contains(where: \.isNumber) }) {
                print("    ⚠️  DIGIT LEAKED: \(offender)")
                throw ExitCode.failure
            }
        }
    }
}
