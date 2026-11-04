import AppKit
import ApplicationServices
import CoreAudio
import MediaRemoteAdapter
import os

private let log = Logger(subsystem: "com.dictascade.app", category: "MediaPlayback")

/// Pauses the Now Playing app while recording and resumes it afterwards
/// (Settings → Media). Opening a Bluetooth headset's microphone switches it to the
/// hands-free profile, which turns music into low-quality mono.
///
/// Follows VoiceInk's `PlaybackController`: the state is read through
/// MediaRemoteAdapter, which runs MediaRemote inside the entitled `/usr/bin/perl`
/// (apps outside Apple cannot read Now Playing since macOS 15.4); pause is the
/// explicit MediaRemote command; playback resumes only when the app we paused is
/// still the Now Playing app and still paused, via the hardware Play/Pause key
/// (some players ignore the MediaRemote play command). When the state cannot be
/// read nothing is toggled, so the feature never starts audio by itself.
///
/// Resuming waits until a Bluetooth output is back in the playback profile: its
/// nominal sample rate drops while the microphone is in use (AirPods Pro 48 → 24 kHz,
/// Bose 44.1 → 16 kHz) and returns 2.3–2.7 s after the microphone closes, right
/// when full quality is audible again. A fixed 1 s delay resumed in call quality.
@MainActor
final class MediaPlaybackController {
    static let shared = MediaPlaybackController()

    static let enabledKey = "pauseMediaWhileRecording"
    static let bluetoothOnlyKey = "pauseMediaOnlyForBluetooth"

    private static let stateTimeout: Duration = .seconds(2)
    /// Upper bound for the headset's return to the playback profile (measured 2.3–2.7 s).
    private static let profileTimeout: Duration = .seconds(5)
    /// After a very short recording the switch to hands-free may not have begun yet.
    private static let handsFreeStartTimeout: Duration = .milliseconds(600)

    private let adapter = MediaRemoteAdapter.MediaController()
    /// Bundle ID of the app this controller paused; nil when it paused nothing.
    private var pausedBundleID: String?
    /// Bumped on every start and stop so late async work from an older session is dropped.
    private var generation: UInt64 = 0
    private var resumeTask: Task<Void, Never>?
    private var lastInputWasBluetooth = false

    private init() {
        UserDefaults.standard.register(defaults: [
            Self.enabledKey: false,
            Self.bluetoothOnlyKey: true,
        ])
    }

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    private var bluetoothOnly: Bool { UserDefaults.standard.bool(forKey: Self.bluetoothOnlyKey) }

    // MARK: - Recording lifecycle

    /// Called once the microphone is open.
    func recordingStarted(inputIsBluetooth: Bool) {
        generation &+= 1
        let session = generation
        // A pending resume from the previous recording is dropped; its pause carries over.
        resumeTask?.cancel()
        resumeTask = nil
        lastInputWasBluetooth = inputIsBluetooth

        guard isEnabled else { return }
        guard !bluetoothOnly || inputIsBluetooth else {
            log.debug("Media pause skipped: input is not Bluetooth")
            return
        }
        guard pausedBundleID == nil else {
            log.notice("Media stays paused from the previous recording")
            return
        }

        Task {
            let info = await currentTrackInfo()
            guard session == generation else { return }
            guard let info, info.isPlaying == true, let bundleID = info.bundleIdentifier else {
                log.notice("Media pause skipped: nothing playing (\(info?.bundleIdentifier ?? "no Now Playing app", privacy: .public))")
                return
            }
            pausedBundleID = bundleID
            adapter.pause()
            log.notice("Paused media: \(bundleID, privacy: .public)")
        }
    }

    /// Called whenever the microphone closes (stop, discard or failure).
    func recordingStopped() {
        generation &+= 1
        let session = generation
        guard let bundleID = pausedBundleID else { return }

        let inputWasBluetooth = lastInputWasBluetooth
        resumeTask?.cancel()
        resumeTask = Task {
            await waitForPlaybackProfile(inputWasBluetooth: inputWasBluetooth)
            guard session == generation, !Task.isCancelled else { return }

            let info = await currentTrackInfo()
            guard session == generation, !Task.isCancelled else { return }
            resumeTask = nil
            pausedBundleID = nil

            guard let info else {
                log.notice("Media resume skipped: Now Playing state unavailable")
                return
            }
            guard info.bundleIdentifier == bundleID else {
                log.notice("Media resume skipped: Now Playing app changed to \(info.bundleIdentifier ?? "none", privacy: .public)")
                return
            }
            guard info.isPlaying == false else {
                log.notice("Media resume skipped: \(bundleID, privacy: .public) already playing")
                return
            }
            let method = resume()
            log.notice("Resumed media: \(bundleID, privacy: .public) via \(method, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// Returns once the default output can play in full quality: immediately for a
    /// wired or built-in output, otherwise when a Bluetooth output's sample rate is
    /// back at 44.1 kHz or more (or after `profileTimeout`).
    private func waitForPlaybackProfile(inputWasBluetooth: Bool) async {
        guard let output = OutputDevice.defaultOutput(), output.isBluetooth else { return }
        let start = ContinuousClock.now
        let waiter = SampleRateWaiter(device: output.id)

        if let rate = output.nominalSampleRate, rate >= OutputDevice.fullQualityRate {
            // Already in the playback profile, unless a very short recording closed the
            // microphone before the switch to hands-free started.
            guard inputWasBluetooth,
                  await waiter.wait(timeout: Self.handsFreeStartTimeout, until: { $0 < OutputDevice.fullQualityRate })
            else { return }
        }

        let restored = await waiter.wait(timeout: Self.profileTimeout, until: { $0 >= OutputDevice.fullQualityRate })
        guard !Task.isCancelled else { return }
        let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
        if restored {
            log.notice("Headset back in playback profile after \(elapsed, privacy: .public)")
        } else {
            log.notice("Headset playback profile not detected within \(elapsed, privacy: .public), resuming anyway")
        }
    }

    private func resume() -> String {
        // Without Accessibility the synthetic key is dropped silently.
        if AXIsProcessTrusted() {
            Self.postPlayPauseKey()
            return "Play/Pause key"
        } else {
            adapter.play()
            return "MediaRemote play"
        }
    }

    /// One-shot Now Playing lookup; nil when it fails or times out.
    private func currentTrackInfo() async -> TrackInfo.Payload? {
        let request = TrackInfoRequest()
        return await withCheckedContinuation { continuation in
            request.continuation = continuation
            adapter.getTrackInfo { info in
                MainActor.assumeIsolated { _ = request.finish(info?.payload) }
            }
            Task {
                try? await Task.sleep(for: Self.stateTimeout)
                if request.finish(nil) {
                    log.notice("Now Playing lookup timed out")
                }
            }
        }
    }

    /// Hardware Play/Pause media key (NX_KEYTYPE_PLAY = 16), as sent by F8.
    private static func postPlayPauseKey() {
        func post(down: Bool) {
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (16 << 16) | ((down ? 0xa : 0xb) << 8),
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }
}

/// Resumes a lookup exactly once: the adapter reply and the timeout race.
@MainActor
private final class TrackInfoRequest {
    var continuation: CheckedContinuation<TrackInfo.Payload?, Never>?

    @discardableResult
    func finish(_ payload: TrackInfo.Payload?) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: payload)
        return true
    }
}

// MARK: - Output device profile

private struct OutputDevice {
    /// Playback (A2DP) runs at 44.1/48 kHz; hands-free at 8–32 kHz.
    static let fullQualityRate: Float64 = 44_100

    let id: AudioDeviceID

    static func defaultOutput() -> OutputDevice? {
        let id: AudioDeviceID? = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        guard let id, id != kAudioObjectUnknown else { return nil }
        return OutputDevice(id: id)
    }

    var isBluetooth: Bool {
        let transport: UInt32? = Self.property(id, kAudioDevicePropertyTransportType)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    var nominalSampleRate: Float64? { Self.nominalSampleRate(of: id) }

    static func nominalSampleRate(of id: AudioDeviceID) -> Float64? {
        property(id, kAudioDevicePropertyNominalSampleRate)
    }

    private static func property<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }
}

/// Waits for a device's nominal sample rate to satisfy a condition, driven by
/// CoreAudio change notifications.
@MainActor
private final class SampleRateWaiter {
    private let device: AudioDeviceID
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var continuation: CheckedContinuation<Bool, Never>?
    private var listener: AudioObjectPropertyListenerBlock?

    init(device: AudioDeviceID) {
        self.device = device
    }

    /// True when the condition was met, false on timeout or cancellation.
    func wait(timeout: Duration, until condition: @escaping (Float64) -> Bool) async -> Bool {
        if isSatisfied(condition) { return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        guard let self, self.isSatisfied(condition) else { return }
                        self.finish(true)
                    }
                }
                self.listener = listener
                AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
                // The rate may have changed before the listener was installed.
                if isSatisfied(condition) {
                    finish(true)
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.finish(false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(false) }
        }
    }

    private func isSatisfied(_ condition: (Float64) -> Bool) -> Bool {
        OutputDevice.nominalSampleRate(of: device).map(condition) ?? false
    }

    private func finish(_ result: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        if let listener {
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
            self.listener = nil
        }
        continuation.resume(returning: result)
    }
}
