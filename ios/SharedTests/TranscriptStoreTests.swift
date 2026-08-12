import Foundation
import XCTest

@testable import DoNotType

/// The app/keyboard bridge.
///
/// This is the whole of what the keyboard extension does: read a file the app wrote into a shared
/// container, insert one entry, mark it used. The extension's own UI cannot be reached by a UI
/// test — a keyboard runs in its own process and does not appear in the host app's accessibility
/// tree — so this covers the part that carries the risk instead of the part that is merely drawn.
final class TranscriptStoreTests: XCTestCase {

    private var directory: URL!
    private var store: TranscriptStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = TranscriptStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAnAppendedTranscriptIsReadableBack() {
        store.append("hello there")
        XCTAssertEqual(store.load().map(\.text), ["hello there"])
    }

    /// Newest first: the keyboard shows the top of the list, and the thing you just said is the
    /// thing you are about to insert.
    func testNewestTranscriptComesFirst() {
        store.append("first")
        store.append("second")
        XCTAssertEqual(store.load().map(\.text), ["second", "first"])
    }

    /// Whitespace-only dictations happen — a hotkey pressed and released without speaking. Storing
    /// them would fill the keyboard's list with blank rows nobody can identify.
    func testEmptyAndBlankTranscriptsAreRejected() {
        XCTAssertNil(store.append(""))
        XCTAssertNil(store.append("   \n\t "))
        XCTAssertTrue(store.load().isEmpty)
    }

    func testSurroundingWhitespaceIsTrimmed() {
        store.append("  spoken words \n")
        XCTAssertEqual(store.load().first?.text, "spoken words")
    }

    /// The container is not a history; the app's own store is. This one is a hand-off buffer and
    /// has to stay bounded, or a keyboard extension's tight memory limit becomes the thing that
    /// decides when it stops working.
    func testTheListIsCappedAndKeepsTheNewest() {
        for index in 1...30 { store.append("entry \(index)") }

        let entries = store.load()
        XCTAssertEqual(entries.count, 25)
        XCTAssertEqual(entries.first?.text, "entry 30")
        XCTAssertEqual(entries.last?.text, "entry 6")
    }

    /// What the keyboard does on a tap. The flag is what lets the list show which transcripts have
    /// already been used, so a second insert is a deliberate act rather than a confusing repeat.
    func testMarkingInsertedSticksAndLeavesOthersAlone() throws {
        store.append("older")
        store.append("newer")
        let newer = try XCTUnwrap(store.load().first)

        store.markInserted(newer.id)

        let entries = store.load()
        XCTAssertTrue(try XCTUnwrap(entries.first).inserted)
        XCTAssertFalse(try XCTUnwrap(entries.last).inserted)
    }

    func testMarkingAnUnknownIdChangesNothing() {
        store.append("only")
        store.markInserted(UUID())
        XCTAssertEqual(store.load().map(\.text), ["only"])
        XCTAssertFalse(store.load()[0].inserted)
    }

    func testClearEmptiesTheContainer() {
        store.append("something")
        store.clear()
        XCTAssertTrue(store.load().isEmpty)
    }

    /// A second `TranscriptStore` over the same directory is the actual arrangement: the app has
    /// one and the keyboard, in a different process, has another. Reading has to work through the
    /// file rather than through anything held in memory.
    func testASeparateStoreOverTheSameDirectorySeesTheSameEntries() {
        store.append("written by the app")

        let keyboardSide = TranscriptStore(directory: directory)
        XCTAssertEqual(keyboardSide.load().map(\.text), ["written by the app"])
    }

    /// Without Full Access there is no shared container at all. Every operation has to be a no-op
    /// rather than a crash, because the keyboard still has to come up and explain itself.
    func testWithoutAContainerEverythingIsANoOp() {
        let unreachable = TranscriptStore(directory: nil)
        XCTAssertNil(unreachable.append("anything"))
        XCTAssertTrue(unreachable.load().isEmpty)
        unreachable.markInserted(UUID())
        unreachable.clear()
    }
}
