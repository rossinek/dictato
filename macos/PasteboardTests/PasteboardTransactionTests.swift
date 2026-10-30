import AppKit
import XCTest

@MainActor
final class PasteboardTransactionTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: .init("com.dictascade.tests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    func testClipboardReaderCannotTriggerEarlyRestoration() async throws {
        pasteboard.setString("original", forType: .string)
        let transaction = PasteboardTransaction(pasteboard: pasteboard, text: "transcription")
        XCTAssertTrue(transaction.didWrite)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcription")
        // A clipboard manager reads before the destination editor does.
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(pasteboard.string(forType: .string), "transcription")
        XCTAssertTrue(transaction.restoreIfOwned())
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testLaterUserCopyIsNeverOverwritten() {
        pasteboard.setString("original", forType: .string)
        let transaction = PasteboardTransaction(pasteboard: pasteboard, text: "transcription")
        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)
        XCTAssertFalse(transaction.restoreIfOwned())
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testSameTextCopiedAgainStillCountsAsNewClipboardOwnership() {
        pasteboard.setString("original", forType: .string)
        let transaction = PasteboardTransaction(pasteboard: pasteboard, text: "transcription")
        pasteboard.clearContents()
        pasteboard.setString("transcription", forType: .string)
        XCTAssertFalse(transaction.restoreIfOwned())
        XCTAssertEqual(pasteboard.string(forType: .string), "transcription")
    }

    func testRestoresAllItemsAndRepresentationsTogether() {
        let first = NSPasteboardItem()
        first.setString("first", forType: .string)
        let richText = Data("{\\rtf1 first}".utf8)
        first.setData(richText, forType: .rtf)
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        pasteboard.writeObjects([first, second])
        let transaction = PasteboardTransaction(pasteboard: pasteboard, text: "transcription")
        XCTAssertTrue(transaction.restoreIfOwned())
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
        XCTAssertEqual(pasteboard.pasteboardItems?[0].data(forType: .rtf), richText)
        XCTAssertEqual(pasteboard.pasteboardItems?[1].string(forType: .string), "second")
    }

    func testOldTransactionCannotOverwriteNewPaste() {
        pasteboard.setString("original", forType: .string)
        let old = PasteboardTransaction(pasteboard: pasteboard, text: "first transcription")
        let new = PasteboardTransaction(pasteboard: pasteboard, text: "second transcription")
        XCTAssertFalse(old.restoreIfOwned())
        XCTAssertTrue(new.ownsClipboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "second transcription")
    }

    func testEmptyOriginalKeepsTranscriptionAvailable() {
        pasteboard.clearContents()
        let transaction = PasteboardTransaction(pasteboard: pasteboard, text: "transcription")
        XCTAssertFalse(transaction.restoreIfOwned())
        XCTAssertEqual(pasteboard.string(forType: .string), "transcription")
    }
}
