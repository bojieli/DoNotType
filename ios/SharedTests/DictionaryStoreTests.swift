import DoNotTypeCore
import Foundation
import XCTest

@testable import DoNotType

final class DictionaryStoreTests: XCTestCase {
    private var directory: URL!
    private var store: DictionaryStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DictionaryStore(directory: directory)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testManualAndLearnedEntriesRemainVisibleAndOrdered() throws {
        try store.add("Kaelith")
        let learned = try store.learn(["SwiftUI"])
        XCTAssertEqual(learned.0.manual, ["Kaelith"])
        XCTAssertEqual(learned.0.learned, ["SwiftUI"])
        XCTAssertEqual(store.load().all, ["Kaelith", "SwiftUI"])
    }

    func testDuplicateLearningAndUndoAreSafe() throws {
        try store.add("Kaelith")
        XCTAssertTrue(try store.learn(["KAELITH"]).1.isEmpty)
        try store.learn(["SwiftUI"])
        try store.forgetLearned(["SwiftUI"])
        XCTAssertEqual(store.load().all, ["Kaelith"])
    }

    func testCSVImportIsAtomicAndLearningFlagPersists() throws {
        try store.setLearning(true)
        let result = try store.importCSV(Data("Kaelith\n\"Smith, Jones\"\n".utf8))
        XCTAssertEqual(result.1, 2)
        XCTAssertTrue(store.load().learnsFromEdits)
        XCTAssertEqual(store.load().manual, ["Kaelith", "Smith, Jones"])
    }

    func testPendingCorrectionExpires() {
        let observations = CorrectionObservationStore(directory: directory)
        observations.save(.init(
            documentID: UUID(), prefix: "before", suffix: "after", inserted: "Keyleth",
            createdAt: Date(timeIntervalSinceNow: -61)))
        XCTAssertNil(observations.load())
    }

    func testMITLicenseShipsInApplicationBundle() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "LICENSE", withExtension: nil))
        let license = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(license.hasPrefix("MIT License\n"))
        XCTAssertTrue(license.contains("Copyright (c) 2026 Bojie Li"))
    }

    func testThirdPartyNoticesShipInApplicationBundle() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt"))
        let notices = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(notices.hasPrefix("DoNotType — Third-Party Notices\n"))
        XCTAssertTrue(notices.contains("Silero VAD"))
    }
}
