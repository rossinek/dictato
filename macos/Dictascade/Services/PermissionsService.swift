import AVFoundation
import AppKit
import os

private let log = Logger(subsystem: "com.dictascade.app", category: "Permissions")

enum PermissionsService {

    // MARK: - Microphone

    static var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophoneAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        log.info("Microphone authorization status: \(String(describing: status.rawValue))")

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            await showMicrophoneAlert()
            return false
        @unknown default:
            return false
        }
    }

    @MainActor
    private static func showMicrophoneAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "Dictascade needs microphone access to record and transcribe your speech.\n\nPlease enable it in System Settings → Privacy & Security → Microphone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    // MARK: - Accessibility

    static var hasAccessibilityAccess: Bool {
        let trusted = AXIsProcessTrusted()
        log.info("AXIsProcessTrusted: \(trusted)")
        return trusted
    }

    static func requestAccessibilityAccess() async -> Bool {
        if AXIsProcessTrusted() {
            log.info("Accessibility access already granted")
            return true
        }

        log.info("Accessibility access not granted, prompting user")
        await showAccessibilityAlert()
        return false
    }

    @MainActor
    private static func showAccessibilityAlert() {
        // Just trigger the system prompt — no custom dialog
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Helpers

    private static func openSystemSettings(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
