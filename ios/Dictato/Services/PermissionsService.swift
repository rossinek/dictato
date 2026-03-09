import AVFoundation
import os

private let log = Logger(subsystem: "com.dictato.app", category: "Permissions")

enum PermissionsService {
    static var hasMicrophoneAccess: Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted
    }

    static func requestMicrophoneAccess() async -> Bool {
        let status = AVAudioSession.sharedInstance().recordPermission
        log.info("Microphone permission status: \(String(describing: status.rawValue))")

        switch status {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}
