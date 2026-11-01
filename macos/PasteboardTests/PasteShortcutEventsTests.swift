import CoreGraphics
import XCTest

final class PasteShortcutEventsTests: XCTestCase {
    func testPasteShortcutReleasesSyntheticCommand() throws {
        let events = try XCTUnwrap(PasteShortcutEvents.make(keyCode: 9, modifiers: .maskCommand))
        XCTAssertEqual(events.down.type, .keyDown)
        XCTAssertEqual(events.up.type, .keyUp)
        XCTAssertEqual(events.down.getIntegerValueField(.keyboardEventKeycode), 9)
        XCTAssertEqual(events.up.getIntegerValueField(.keyboardEventKeycode), 9)
        XCTAssertTrue(events.down.flags.contains(.maskCommand))
        XCTAssertEqual(events.up.flags.rawValue, 0, "Key-up must not leave Command held for the next paste")
    }

    func testCustomPasteShortcutsAlsoReleaseAllTheirModifiers() throws {
        for flags: CGEventFlags in [[.maskCommand, .maskShift], [.maskControl, .maskAlternate], [.maskCommand, .maskAlternate, .maskShift]] {
            let events = try XCTUnwrap(PasteShortcutEvents.make(keyCode: 9, modifiers: flags))
            XCTAssertEqual(events.down.flags, flags)
            XCTAssertEqual(events.up.flags.rawValue, 0)
        }
    }
}
