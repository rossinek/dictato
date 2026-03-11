import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.dictascade.app", category: "PasteService")

enum PasteService {
    static func paste(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard PermissionsService.hasAccessibilityAccess else {
            log.warning("No accessibility access — text copied to clipboard but cannot auto-paste")
            return
        }

        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 0x09 = 'v'
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)

        log.info("Pasted text via Cmd+V")
    }
}
