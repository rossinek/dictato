import CoreGraphics

/// Builds a complete synthetic shortcut without leaving its modifiers held.
enum PasteShortcutEvents {
    static func make(keyCode: CGKeyCode, modifiers: CGEventFlags) -> (down: CGEvent, up: CGEvent)? {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return nil
        }
        down.flags = modifiers
        // Do not copy modifiers onto key-up: Quartz retains them and the next
        // paste waits for a Command key that the user is not actually holding.
        // PasteService checks that physical modifiers are released before posting.
        // Regression details and end-to-end checks: docs/automatic-paste.md.
        up.flags = []
        return (down, up)
    }
}
