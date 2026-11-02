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

    /// Types `text` into the application with `targetPID`. Stops if focus moves to
    /// another application, the task is cancelled, or the user keeps holding a
    /// modifier (which would turn typed characters into shortcuts).
    @MainActor
    static func type(
        _ text: String,
        targetPID: pid_t?,
        modifiersPressed: () -> Bool
    ) async -> Result {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return .interrupted(reason: "could not create event source")
        }

        for (index, chunk) in chunks(for: text).enumerated() {
            if index > 0 {
                do { try await Task.sleep(for: .milliseconds(2)) } catch {
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

            switch chunk {
            case .text(let units):
                guard post(units, source: source) else {
                    return .interrupted(reason: "could not create key event")
                }
            case .lineBreak:
                guard let events = PasteShortcutEvents.make(keyCode: returnKeyCode, modifiers: .maskShift) else {
                    return .interrupted(reason: "could not create key event")
                }
                events.down.post(tap: .cghidEventTap)
                events.up.post(tap: .cghidEventTap)
            }
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
}
