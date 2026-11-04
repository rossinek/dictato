import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.dictascade.app", category: "PasteService")

/// Inserts text as Unicode keyboard events without touching the clipboard.
///
/// Used only where pasting is known to fail (see `ChromiumEngineDetector`) or when the
/// user selects it for an application. It is not a universal replacement for paste:
/// Safari reordered fast chunks, TextEdit applied smart quotes, and a typed Return
/// submits commands and chat messages (docs/automatic-paste.md).
enum KeyboardTyper {
    /// Unicode strings longer than this are not reliably delivered in one event.
    static let maxUTF16UnitsPerEvent = 20
    private static let returnKeyCode: CGKeyCode = 36

    enum Chunk: Equatable {
        case text([UniChar])
        /// Sent as Shift+Return so chat and form fields insert a line break instead of submitting.
        case lineBreak
    }

    enum Result: Equatable {
        case completed
        case interrupted(reason: String)
    }

    /// Splits text into keyboard events without splitting grapheme clusters
    /// (emoji, combining marks, surrogate pairs).
    static func chunks(for text: String, maxUTF16Units: Int = maxUTF16UnitsPerEvent) -> [Chunk] {
        var result: [Chunk] = []
        var current: [UniChar] = []

        func flush() {
            if !current.isEmpty {
                result.append(.text(current))
                current = []
            }
        }

        for character in text {
            if character.isNewline {
                flush()
                result.append(.lineBreak)
                continue
            }
            let units = Array(String(character).utf16)
            if !current.isEmpty && current.count + units.count > maxUTF16Units {
                flush()
            }
            // A single oversized cluster is sent whole rather than split.
            current += units
        }
        flush()
        return result
    }

    /// How characters are encoded in keyboard events.
    enum Mode: Equatable {
        /// The text travels as the event's Unicode string (virtual key 0); works in
        /// Cocoa/Chromium text fields regardless of the keyboard layout.
        case unicode
        /// Each character is sent as the physical key (plus Shift/Option) that produces
        /// it in the current layout, for apps that read only key codes. Characters the
        /// layout cannot produce without dead keys fall back to Unicode events.
        case keyCodes
    }

    enum KeyStep: Equatable {
        case key(KeyLayoutMap.Keystroke, text: [UniChar])
        case unicode([UniChar])
        case lineBreak
    }

    /// Plans key-code typing: one key per mapped character; runs of unmapped
    /// characters become Unicode chunks of at most `maxUTF16Units`.
    static func keySteps(
        for text: String,
        map: KeyLayoutMap,
        maxUTF16Units: Int = maxUTF16UnitsPerEvent
    ) -> [KeyStep] {
        var result: [KeyStep] = []
        var fallback = ""

        func flushFallback() {
            for case .text(let units) in chunks(for: fallback, maxUTF16Units: maxUTF16Units) {
                result.append(.unicode(units))
            }
            fallback = ""
        }

        for character in text {
            if character.isNewline {
                flushFallback()
                result.append(.lineBreak)
            } else if let keystroke = map.keystroke(for: character) {
                flushFallback()
                result.append(.key(keystroke, text: Array(String(character).utf16)))
            } else {
                fallback.append(character)
            }
        }
        flushFallback()
        return result
    }

    /// Types `text` into the application with `targetPID`. Stops if focus moves to
    /// another application, the task is cancelled, or the user keeps holding a
    /// modifier (which would turn typed characters into shortcuts).
    @MainActor
    static func type(
        _ text: String,
        mode: Mode = .unicode,
        targetPID: pid_t?,
        modifiersPressed: () -> Bool
    ) async -> Result {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return .interrupted(reason: "could not create event source")
        }

        let steps: [KeyStep]
        switch mode {
        case .unicode:
            steps = chunks(for: text).map { chunk in
                switch chunk {
                case .text(let units): .unicode(units)
                case .lineBreak: .lineBreak
                }
            }
        case .keyCodes:
            guard let map = KeyLayoutMap.current() else {
                return .interrupted(reason: "current keyboard layout has no key layout data")
            }
            steps = keySteps(for: text, map: map)
            let fallbackCount = steps.reduce(0) { count, step in
                if case .unicode(let units) = step { return count + String(utf16CodeUnits: units, count: units.count).count }
                return count
            }
            if fallbackCount > 0 {
                log.notice("Typing keys: \(fallbackCount) characters are not on the keyboard layout; sending them as Unicode")
            }
        }

        for (index, step) in steps.enumerated() {
            if index > 0 {
                do { try await Task.sleep(for: .milliseconds(mode == .unicode ? 2 : 1)) } catch {
                    return .interrupted(reason: "cancelled")
                }
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while modifiersPressed() {
                guard ContinuousClock.now < deadline else {
                    return .interrupted(reason: "modifier keys held")
                }
                do { try await Task.sleep(for: .milliseconds(25)) } catch {
                    return .interrupted(reason: "cancelled")
                }
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
                return .interrupted(reason: "focus changed")
            }

            let posted: Bool
            switch (step, mode) {
            case (.unicode(let units), _):
                posted = post(units, source: source)
            case (.key(let keystroke, let units), _):
                posted = press(keystroke, text: units, source: source)
            case (.lineBreak, .unicode):
                guard let events = PasteShortcutEvents.make(keyCode: returnKeyCode, modifiers: .maskShift) else {
                    return .interrupted(reason: "could not create key event")
                }
                events.down.post(tap: .cghidEventTap)
                events.up.post(tap: .cghidEventTap)
                posted = true
            case (.lineBreak, .keyCodes):
                // Apps reading key codes track modifier keys, not event flags.
                posted = press(KeyLayoutMap.Keystroke(keyCode: returnKeyCode, modifiers: .maskShift), text: nil, source: source)
            }
            guard posted else { return .interrupted(reason: "could not create key event") }
        }
        return .completed
    }

    private static func post(_ units: [UniChar], source: CGEventSource) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            log.error("Could not create typing events")
            return false
        }
        for event in [down, up] {
            event.flags = []
            units.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            }
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Modifier keys pressed for key-code typing, in press order.
    static let modifierKeys: [(flag: CGEventFlags, keyCode: CGKeyCode)] = [
        (.maskShift, 56),     // kVK_Shift
        (.maskAlternate, 58), // kVK_Option
    ]

    /// Events for one key press: modifier keys down, key down/up, modifier keys up.
    /// The last event always has empty flags, so no synthetic modifier stays held
    /// (docs/automatic-paste.md).
    static func pressEvents(
        _ keystroke: KeyLayoutMap.Keystroke,
        text: [UniChar]?,
        source: CGEventSource?
    ) -> [CGEvent]? {
        let modifiers = modifierKeys.filter { keystroke.modifiers.contains($0.flag) }
        var events: [CGEvent] = []
        var flags: CGEventFlags = []

        func modifierEvent(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) -> CGEvent? {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return nil }
            event.type = .flagsChanged
            event.flags = flags
            return event
        }

        for modifier in modifiers {
            flags.insert(modifier.flag)
            guard let event = modifierEvent(modifier.keyCode, down: true, flags: flags) else { return nil }
            events.append(event)
        }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keystroke.keyCode, keyDown: down) else {
                return nil
            }
            event.flags = flags
            if let text {
                text.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
            }
            events.append(event)
        }
        for modifier in modifiers.reversed() {
            flags.remove(modifier.flag)
            guard let event = modifierEvent(modifier.keyCode, down: false, flags: flags) else { return nil }
            events.append(event)
        }
        return events
    }

    private static func press(_ keystroke: KeyLayoutMap.Keystroke, text: [UniChar]?, source: CGEventSource) -> Bool {
        guard let events = pressEvents(keystroke, text: text, source: source) else {
            log.error("Could not create key events")
            return false
        }
        for event in events {
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}
