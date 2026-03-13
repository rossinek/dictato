import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.dictascade.app", category: "PasteService")

final class PasteService: NSObject, NSPasteboardItemDataProvider {

    private static var current: PasteService?

    private let textToProvide: String
    private let savedItems: [[(NSPasteboard.PasteboardType, Data)]]
    private var fulfilled = false
    private var restored = false
    private var timeoutWork: DispatchWorkItem?

    private init(text: String, savedItems: [[(NSPasteboard.PasteboardType, Data)]]) {
        self.textToProvide = text
        self.savedItems = savedItems
        super.init()
    }

    // MARK: - Public API

    static func paste(text: String) {
        let autoPaste = UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true
        let shouldRestore = autoPaste && (UserDefaults.standard.object(forKey: "restoreClipboard") as? Bool ?? true)
        let pasteboard = NSPasteboard.general

        // If restore is disabled, use simple direct paste
        guard shouldRestore else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if autoPaste {
                Self.simulateCmdV()
            } else {
                log.info("Text copied to clipboard (auto-paste disabled)")
            }
            return
        }

        // Save current clipboard contents (all types per item)
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        } ?? []

        let instance = PasteService(text: text, savedItems: saved)
        current = instance

        // Write transcription as promised data
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(instance, forTypes: [.string])
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])

        guard PermissionsService.hasAccessibilityAccess else {
            log.warning("No accessibility access — text on clipboard for manual paste")
            current = nil
            return
        }

        Self.simulateCmdV()

        // Safety timeout: restore after 2s if callback never fires
        let timeout = DispatchWorkItem { [weak instance] in
            instance?.restoreClipboard()
        }
        instance.timeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: timeout)
    }

    // MARK: - NSPasteboardItemDataProvider

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if type == .string, let data = textToProvide.data(using: .utf8) {
            item.setData(data, forType: .string)
            fulfilled = true
            log.info("Provided text to consuming app")
            // Delay restore to let the target app finish processing the paste
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                restoreClipboard()
            }
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        if fulfilled {
            restoreClipboard()
        } else {
            log.info("Pasteboard ownership changed before paste was consumed — skipping restore")
            cleanup()
        }
    }

    // MARK: - Private

    private func restoreClipboard() {
        guard !restored else { return }
        restored = true
        timeoutWork?.cancel()
        timeoutWork = nil

        guard !savedItems.isEmpty else {
            log.info("Clipboard was empty before paste — keeping transcription")
            cleanup()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        for itemTypes in savedItems {
            let item = NSPasteboardItem()
            for (type, data) in itemTypes {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
        log.info("Restored previous clipboard contents")
        cleanup()
    }

    private static func simulateCmdV() {
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

    private func cleanup() {
        if PasteService.current === self {
            PasteService.current = nil
        }
    }
}
