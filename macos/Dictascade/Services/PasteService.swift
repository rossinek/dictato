import AppKit
import CoreGraphics
import KeyboardShortcuts
import os

private let log = Logger(subsystem: "com.dictascade.app", category: "PasteService")

@MainActor
final class PasteService {
    private static var current: PasteboardTransaction?
    private static var restoreWork: DispatchWorkItem?
    private static var pendingPaste: Task<Void, Never>?

    static func paste(text: String) {
        pendingPaste?.cancel()
        // The previous restore timer must not change the clipboard while this
        // request is waiting for the shortcut keys to be released.
        restoreWork?.cancel()
        restoreWork = nil
        let autoPaste = UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true
        let shouldRestore = autoPaste && (UserDefaults.standard.object(forKey: "restoreClipboard") as? Bool ?? true)
        let target = NSWorkspace.shared.frontmostApplication
        let targetPID = target?.processIdentifier
        let clipboardVersion = NSPasteboard.general.changeCount

        pendingPaste = Task { @MainActor in
            if autoPaste && PermissionsService.hasAccessibilityAccess {
                // Allow the recording shortcut/menu to finish and the editor to settle.
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                let deadline = ContinuousClock.now + .seconds(2)
                while physicalModifiersArePressed {
                    guard ContinuousClock.now < deadline else {
                        log.warning("Paste deferred: shortcut modifiers remained pressed; copying text only")
                        if NSPasteboard.general.changeCount == clipboardVersion {
                            copy(text: text)
                            current = nil
                        }
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                // Do not paste into another app or clobber a copy made during the wait.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
                      NSPasteboard.general.changeCount == clipboardVersion else {
                    log.info("Paste cancelled: destination or clipboard changed while waiting")
                    current?.restoreIfOwned()
                    current = nil
                    return
                }
            }

            let transaction = copy(text: text, isTransient: shouldRestore && PermissionsService.hasAccessibilityAccess)
            guard transaction.didWrite else {
                log.error("Could not write transcription to clipboard")
                return
            }
            guard autoPaste, PermissionsService.hasAccessibilityAccess else {
                log.info("Transcription copied; automatic paste unavailable or disabled")
                current = nil
                return
            }

            // Give the pasteboard server time to publish before posting the shortcut.
            do { try await Task.sleep(for: .milliseconds(75)) } catch { return }
            guard transaction.ownsClipboard,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
                  !physicalModifiersArePressed else {
                log.info("Paste skipped: clipboard, focus or keyboard state changed; no shortcut sent")
                if current === transaction { current = nil }
                return
            }
            guard await simulatePasteShortcut() else {
                if current === transaction { current = nil }
                return
            }

            guard shouldRestore else {
                if current === transaction { current = nil }
                return
            }
            // Reading the clipboard is not a paste acknowledgement (clipboard managers
            // read it too). Keep the concrete payload available for delayed app reads.
            let work = DispatchWorkItem {
                if transaction.restoreIfOwned() {
                    log.info("Restored clipboard after paste grace period")
                } else {
                    log.info("Clipboard restoration skipped: contents changed or original was empty")
                }
                if current === transaction { current = nil }
            }
            restoreWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    @discardableResult
    private static func copy(text: String, isTransient: Bool = false) -> PasteboardTransaction {
        restoreWork?.cancel()
        restoreWork = nil
        current?.restoreIfOwned()
        let transaction = PasteboardTransaction(pasteboard: .general, text: text, isTransient: isTransient)
        current = transaction
        return transaction
    }

    private static var physicalModifiersArePressed: Bool {
        let flags = CGEventSource.flagsState(.hidSystemState)
        return !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty
    }

    private static func simulatePasteShortcut() async -> Bool {
        guard PermissionsService.hasAccessibilityAccess else { return false }
        let shortcut = resolvedPasteShortcut()
        let keyCode = CGKeyCode(truncatingIfNeeded: shortcut.carbonKeyCode)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            log.error("Could not create paste shortcut events")
            return false
        }
        let flags = cgEventFlags(from: shortcut.modifiers)
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        // Always release the key, including when a newer paste cancels this task.
        try? await Task.sleep(for: .milliseconds(20))
        keyUp.post(tap: .cghidEventTap)
        log.info("Sent paste shortcut to \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown", privacy: .public)")
        return true
    }

    private static func resolvedPasteShortcut() -> KeyboardShortcuts.Shortcut {
        let defaultShortcut = KeyboardShortcuts.Shortcut(.v, modifiers: .command)

        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let exception = ApplicationPasteExceptionStore.exception(for: bundleIdentifier),
              let customShortcut = KeyboardShortcuts.getShortcut(for: exception.shortcutName) else {
            return defaultShortcut
        }

        log.info(
            "Using custom paste shortcut for \(exception.applicationName, privacy: .public) (\(bundleIdentifier, privacy: .public))"
        )
        return customShortcut
    }

    private static func cgEventFlags(
        from modifiers: NSEvent.ModifierFlags
    ) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.numericPad) { flags.insert(.maskNumericPad) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

}
