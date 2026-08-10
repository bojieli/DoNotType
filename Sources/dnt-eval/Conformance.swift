import ArgumentParser
import DoNotTypeCore
import Foundation

/// Regenerates or checks the cross-platform encoder golden file.
///
/// Swift is the reference implementation, so this writes what the other three ports must match.
/// Regenerating is deliberately a separate, explicit command rather than something a failing test
/// offers to do for you: a golden file that rewrites itself on mismatch records the bug instead of
/// catching it.
struct Conformance: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check or regenerate the cross-platform ContextEncoder golden file.")

    @Flag(name: .long, help: "Overwrite golden.json with the current Swift output.")
    var write = false

    mutating func run() async throws {
        guard let directory = ConformanceFixture.directory() else {
            throw ValidationError("Could not find eval/conformance/contexts.json")
        }
        let contexts = directory.appendingPathComponent("contexts.json")
        let golden = directory.appendingPathComponent("golden.json")

        let cases = try ConformanceFixture.loadCases(from: contexts)
        let produced = ConformanceFixture.encode(cases)

        if write {
            try ConformanceFixture.write(produced, to: golden)
            print("wrote \(produced.count) cases to \(golden.path)")
            print("Every port must now match this file. Run their suites before committing.")
            return
        }

        let expected = try ConformanceFixture.loadExpectations(from: golden)
        var failures = 0

        for (index, expectation) in expected.enumerated() {
            guard index < produced.count else {
                print("MISSING  \(expectation.id)")
                failures += 1
                continue
            }
            let actual = produced[index]
            if actual.parts == expectation.parts {
                print("ok       \(expectation.id)")
            } else {
                failures += 1
                print("MISMATCH \(expectation.id) — \(expectation.why)")
                for (partIndex, part) in expectation.parts.enumerated() {
                    let got = partIndex < actual.parts.count ? actual.parts[partIndex] : nil
                    guard got != part else { continue }
                    print("  part \(partIndex) expected: \(describe(part))")
                    print("  part \(partIndex) got:      \(got.map(describe) ?? "<missing>")")
                }
            }
        }

        print("\n\(expected.count - failures)/\(expected.count) cases match")
        if failures > 0 {
            throw ExitCode(1)
        }
    }

    private func describe(_ part: ConformanceFixture.EncodedPart) -> String {
        switch part.type {
        case "text": "text(\(part.text?.count ?? 0) chars) \(String((part.text ?? "").prefix(120)).debugDescription)"
        default: "\(part.type)(\(part.bytes ?? 0) bytes, \(part.mimeType ?? "?"))"
        }
    }
}
