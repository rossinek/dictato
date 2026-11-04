import CoreGraphics
import XCTest

final class KeyLayoutMapTests: XCTestCase {
    private typealias Keystroke = KeyLayoutMap.Keystroke

    /// A tiny Polish Programmer-like layout: a/A/ą/Ą on key 0, a dead key on 14 with Option,
    /// a digit duplicated on the keypad, Return producing a control character.
    private func translate(_ keyCode: CGKeyCode, _ modifiers: CGEventFlags) -> String? {
        switch (keyCode, modifiers) {
        case (0, []): "a"
        case (0, .maskShift): "A"
        case (0, .maskAlternate): "ą"
        case (0, [.maskShift, .maskAlternate]): "Ą"
        case (14, []): "e"
        case (14, .maskAlternate): nil // dead key
        case (18, []): "1"
        case (18, .maskShift): "!"
        case (83, []): "1" // kVK_ANSI_Keypad1
        case (84, []): "2" // kVK_ANSI_Keypad2, only on the keypad
        case (36, _): "\r"
        case (49, []): " "
        case (12, .maskAlternate): "a" // a duplicate needing a modifier
        default: nil
        }
    }

    func testMapsCharactersToKeysWithFewestModifiers() {
        let map = KeyLayoutMap(translate: translate)
        XCTAssertEqual(map.keystroke(for: "a"), Keystroke(keyCode: 0, modifiers: []))
        XCTAssertEqual(map.keystroke(for: "A"), Keystroke(keyCode: 0, modifiers: .maskShift))
        XCTAssertEqual(map.keystroke(for: "ą"), Keystroke(keyCode: 0, modifiers: .maskAlternate))
        XCTAssertEqual(map.keystroke(for: "Ą"), Keystroke(keyCode: 0, modifiers: [.maskShift, .maskAlternate]))
        XCTAssertEqual(map.keystroke(for: "!"), Keystroke(keyCode: 18, modifiers: .maskShift))
        XCTAssertEqual(map.keystroke(for: " "), Keystroke(keyCode: 49, modifiers: []))
    }

    func testSkipsKeypadDeadKeysAndControlCharacters() {
        let map = KeyLayoutMap(translate: translate)
        XCTAssertEqual(map.keystroke(for: "1"), Keystroke(keyCode: 18, modifiers: []))
        XCTAssertNil(map.keystroke(for: "2"))
        XCTAssertNil(map.keystroke(for: "\r"))
        XCTAssertNil(map.keystroke(for: "é"))
    }

    func testDecomposedTextMatchesPrecomposedKey() {
        let map = KeyLayoutMap(translate: translate)
        XCTAssertEqual(map.keystroke(for: "a\u{328}"), Keystroke(keyCode: 0, modifiers: .maskAlternate))
    }

    func testKeyStepsUseKeysAndFallBackToUnicode() {
        let map = KeyLayoutMap(translate: translate)
        let steps = KeyboardTyper.keySteps(for: "Ą e!\n— 👍a", map: map)
        XCTAssertEqual(steps, [
            .key(Keystroke(keyCode: 0, modifiers: [.maskShift, .maskAlternate]), text: Array("Ą".utf16)),
            .key(Keystroke(keyCode: 49, modifiers: []), text: [32]),
            .key(Keystroke(keyCode: 14, modifiers: []), text: Array("e".utf16)),
            .key(Keystroke(keyCode: 18, modifiers: .maskShift), text: Array("!".utf16)),
            .lineBreak,
            .unicode(Array("—".utf16)),
            .key(Keystroke(keyCode: 49, modifiers: []), text: [32]),
            .unicode(Array("👍".utf16)),
            .key(Keystroke(keyCode: 0, modifiers: []), text: Array("a".utf16)),
        ])
    }

    func testUnmappedRunsRespectEventLimit() {
        let map = KeyLayoutMap(translate: translate)
        let steps = KeyboardTyper.keySteps(for: String(repeating: "ж", count: 45), map: map)
        XCTAssertEqual(steps.count, 3)
        for case .unicode(let units) in steps {
            XCTAssertLessThanOrEqual(units.count, KeyboardTyper.maxUTF16UnitsPerEvent)
        }
    }

    func testPressEventsReleaseModifiersAndEndWithEmptyFlags() throws {
        let keystroke = Keystroke(keyCode: 0, modifiers: [.maskShift, .maskAlternate])
        let events = try XCTUnwrap(KeyboardTyper.pressEvents(keystroke, text: Array("Ą".utf16), source: nil))
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [56, 58, 0, 0, 58, 56])
        let relevant: CGEventFlags = [.maskShift, .maskAlternate]
        XCTAssertEqual(events.map { $0.flags.intersection(relevant) }, [
            .maskShift, relevant, relevant, relevant, .maskShift, [],
        ])
    }

    func testUnmodifiedPressIsKeyDownAndUpOnly() throws {
        let events = try XCTUnwrap(KeyboardTyper.pressEvents(Keystroke(keyCode: 14, modifiers: []), text: nil, source: nil))
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertTrue(events.allSatisfy { $0.flags.intersection([.maskShift, .maskAlternate]).isEmpty })
    }

    func testCurrentLayoutMapsBasicLatinLetters() throws {
        // Every macOS Latin layout produces lowercase "e" and space without modifiers.
        let map = try XCTUnwrap(MainActor.assumeIsolated { KeyLayoutMap.current() })
        XCTAssertEqual(map.keystroke(for: " ")?.keyCode, 49)
        XCTAssertNotNil(map.keystroke(for: "e"))
    }
}
