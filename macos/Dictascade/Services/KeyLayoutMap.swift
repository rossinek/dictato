import Carbon.HIToolbox
import CoreGraphics

/// Maps characters to the physical keys that produce them in a keyboard layout.
///
/// Used by `KeyboardTyper` in key-code mode for applications that read the virtual
/// key code and ignore the Unicode string of synthetic events (remote desktops,
/// virtual machines, some terminals and games). Such apps turn every Unicode event
/// (virtual key 0 = A) into "a".
struct KeyLayoutMap {
    struct Keystroke: Equatable {
        let keyCode: CGKeyCode
        /// Only `.maskShift` and `.maskAlternate` are used.
        let modifiers: CGEventFlags
    }

    /// Modifier combinations tried in order; the first (fewest modifiers) wins.
    static let modifierCombinations: [CGEventFlags] = [
        [], .maskShift, .maskAlternate, [.maskShift, .maskAlternate],
    ]

    /// Keypad keys (kVK_ANSI_KeypadDecimal…kVK_ANSI_Keypad9) duplicate main-row digits and
    /// symbols, and some apps treat them as navigation keys.
    private static let keypadKeyCodes: ClosedRange<CGKeyCode> = 65...92

    private let keystrokes: [Character: Keystroke]

    init(keystrokes: [Character: Keystroke]) {
        self.keystrokes = keystrokes
    }

    /// Builds the map from `translate`, which returns the text a key produces with the
    /// given modifiers, or nil for dead keys and keys that produce nothing.
    init(translate: (CGKeyCode, CGEventFlags) -> String?) {
        var keystrokes: [Character: Keystroke] = [:]
        for modifiers in Self.modifierCombinations {
            for keyCode in CGKeyCode(0)...127 where !Self.keypadKeyCodes.contains(keyCode) {
                guard let output = translate(keyCode, modifiers), output.count == 1,
                      let character = output.first,
                      // Return, Tab, Delete, Escape, arrows and function keys produce controls.
                      !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                      keystrokes[character] == nil else { continue }
                keystrokes[character] = Keystroke(keyCode: keyCode, modifiers: modifiers)
            }
        }
        self.keystrokes = keystrokes
    }

    func keystroke(for character: Character) -> Keystroke? {
        keystrokes[character]
    }

    var isEmpty: Bool { keystrokes.isEmpty }

    /// The map for the current keyboard layout. Must be called on the main thread
    /// (Text Input Sources). Returns nil when the layout has no Unicode key layout data.
    @MainActor
    static func current() -> KeyLayoutMap? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())

        let map = layoutData.withUnsafeBytes { buffer -> KeyLayoutMap? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            return KeyLayoutMap { keyCode, modifiers in
                var carbonModifiers: UInt32 = 0
                if modifiers.contains(.maskShift) { carbonModifiers |= UInt32(shiftKey) }
                if modifiers.contains(.maskAlternate) { carbonModifiers |= UInt32(optionKey) }
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(
                    layout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDown),
                    (carbonModifiers >> 8) & 0xFF,
                    keyboardType,
                    0, // dead keys enabled, so they can be detected and skipped
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                // A dead key only starts a composition; typing it would not insert its glyph.
                guard status == noErr, deadKeyState == 0, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
        return map.flatMap { $0.isEmpty ? nil : $0 }
    }
}
