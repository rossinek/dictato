@preconcurrency import AVFoundation
import os

private let log = Logger(subsystem: "com.dictascade.app", category: "AudioRecorder")

/// Captures the microphone chosen by the priority list (Settings → Microphone) and
/// delivers 16 kHz mono Float32 samples on the main actor.
///
/// Uses AVCaptureSession rather than AVAudioEngine: it opens only the selected device
/// (AVAudioEngine first opens the system default, which with AirPods connected cost
/// ~1 s even when recording from the built-in microphone), converts to 16 kHz mono
/// itself, and keeps delivering through Bluetooth profile switches without restarts.
@MainActor
final class AudioRecorder {
    /// Samples (16 kHz mono).
    var onSamples: (([Float]) -> Void)?
    /// The device changed during a recording (fail-over after a disconnect).
    var onDeviceChange: ((String) -> Void)?
    /// Capture cannot continue; the recorder has already stopped.
    var onFailure: ((String) -> Void)?

    private(set) var deviceName: String?
    /// The current input is a Bluetooth device (opening it switches a headset to the hands-free profile).
    var isBluetoothInput: Bool { input?.device.isBluetooth ?? false }
    /// True between `start()` and `stop()`, including while paused.
    var isActive: Bool { session != nil }

    private var session: AVCaptureSession?
    private var input: AVCaptureDeviceInput?
    private var isPaused = false
    private var observers: [NSObjectProtocol] = []
    private var startTime: ContinuousClock.Instant?
    private var receivedAudio = false
    private var lastRestart: ContinuousClock.Instant?
    /// Last buffer that carried signal; see `checkForDeadInput()`.
    private var lastSignal: ContinuousClock.Instant = .now
    private var watchdog: Task<Void, Never>?
    private let sessionQueue = DispatchQueue(label: "com.dictascade.audio-session")
    private let sampleQueue = DispatchQueue(label: "com.dictascade.audio-samples")
    private var sink: SampleSink?

    // MARK: - Lifecycle

    func start() throws {
        stop()
        let device = try preferredDevice()
        let input = try AVCaptureDeviceInput(device: device)
        let session = AVCaptureSession()
        guard session.canAddInput(input) else { throw RecorderError.cannotUse(device.localizedName) }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let sink = SampleSink { [weak self] samples in
            Task { @MainActor [weak self] in self?.deliver(samples, from: session) }
        }
        output.setSampleBufferDelegate(sink, queue: sampleQueue)
        guard session.canAddOutput(output) else { throw RecorderError.cannotUse(device.localizedName) }
        session.addOutput(output)

        self.session = session
        self.input = input
        self.sink = sink
        deviceName = device.localizedName
        isPaused = false
        observe(session)
        run(session)
    }

    func pause() {
        guard let session, !isPaused else { return }
        isPaused = true
        watchdog?.cancel()
        sessionQueue.async { session.stopRunning() }
    }

    func resume() throws {
        guard let session, isPaused else { return }
        isPaused = false
        if let input, !input.device.isConnected {
            try switchDevice(replacing: input.device)
        }
        run(session)
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        watchdog?.cancel()
        watchdog = nil
        if let session {
            sessionQueue.async { session.stopRunning() }
        }
        session = nil
        input = nil
        sink = nil
        deviceName = nil
        isPaused = false
        lastRestart = nil
    }

    // MARK: - Device selection

    /// First connected entry of the priority list; Auto is the system default input.
    private func preferredDevice(excluding excludedUID: String? = nil) throws -> AVCaptureDevice {
        let available = AudioInputDevices.all().filter { $0.uid != excludedUID }
        let resolved = InputDeviceResolver.resolve(
            InputDevicePreferenceStore.load(),
            available: available,
            builtInMicrophoneUnavailable: AudioInputDevices.isClamshellClosed
        )
        if case .device(let device, let priority) = resolved,
           let captureDevice = AVCaptureDevice(uniqueID: device.uid) {
            log.info("Using microphone \(device.name, privacy: .public) (priority \(priority))")
            return captureDevice
        }
        if let systemDefault = AVCaptureDevice.default(for: .audio), systemDefault.uniqueID != excludedUID {
            log.info("Using system default microphone \(systemDefault.localizedName, privacy: .public)")
            return systemDefault
        }
        // The system default may still point at a device that just disconnected or
        // delivers no audio. Prefer the built-in microphone over virtual devices.
        let builtInUsable = !AudioInputDevices.isClamshellClosed
        let builtInFirst = available.filter { builtInUsable && $0.transport == .builtIn }
            + available.filter { $0.transport != .builtIn }
        if let fallback = builtInFirst.lazy.compactMap({ AVCaptureDevice(uniqueID: $0.uid) }).first {
            log.info("Using microphone \(fallback.localizedName, privacy: .public)")
            return fallback
        }
        throw RecorderError.noMicrophone
    }

    /// Replaces the session input in place; already captured samples are kept.
    private func switchDevice(replacing old: AVCaptureDevice) throws {
        guard let session else { return }
        let device = try preferredDevice(excluding: old.uniqueID)
        let newInput = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else {
            session.commitConfiguration()
            throw RecorderError.cannotUse(device.localizedName)
        }
        session.addInput(newInput)
        session.commitConfiguration()
        input = newInput
        deviceName = device.localizedName
        onDeviceChange?(device.localizedName)
        observeDisconnect(of: device)
    }

    private func deviceDidDisconnect(_ device: AVCaptureDevice) {
        guard let session, input?.device.uniqueID == device.uniqueID else { return }
        log.warning("Microphone \(device.localizedName, privacy: .public) disconnected; switching to the next available input")
        // While paused, resume() switches devices.
        guard !isPaused else { return }
        do {
            try switchDevice(replacing: device)
            run(session)
        } catch {
            fail("Microphone disconnected: \(error.localizedDescription)")
        }
    }

    // MARK: - Session plumbing

    private func run(_ session: AVCaptureSession) {
        startTime = .now
        receivedAudio = false
        lastSignal = .now
        startWatchdog()
        sessionQueue.async {
            if !session.isRunning { session.startRunning() }
        }
    }

    // MARK: - Dead Bluetooth input

    /// Bluetooth headsets deliver ~1.5–2.2 s of digital silence while switching to the
    /// headset profile. When that switch fails — typically when recording starts while
    /// the headset is still leaving the profile after the previous recording, e.g. while
    /// the completion sound plays over A2DP — bluetoothd gives up after several seconds
    /// and the session keeps delivering silence without any error. Real microphones
    /// never fall to -120 dBFS (AirPods' noise floor is around -50 dBFS).
    private static let deadInputTimeout: Duration = .seconds(4)
    private static let signalThreshold: Float = 1e-6

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.checkForDeadInput()
            }
        }
    }

    private func checkForDeadInput() {
        guard let session, !isPaused, let device = input?.device, device.isBluetooth else { return }
        let silent = ContinuousClock.now - lastSignal
        guard silent >= Self.deadInputTimeout else { return }
        let seconds = Double(silent.components.seconds) + Double(silent.components.attoseconds) / 1e18
        log.warning("No audio from \(device.localizedName, privacy: .public) for \(String(format: "%.1f", seconds), privacy: .public) s (headset profile did not start); switching to the next available input")
        do {
            try switchDevice(replacing: device)
            run(session)
        } catch {
            fail("No audio from \(device.localizedName)")
        }
    }

    private func deliver(_ samples: [Float], from source: AVCaptureSession) {
        // Drop late buffers from a stopped or paused session.
        guard source === session, !isPaused else { return }
        if samples.contains(where: { abs($0) > Self.signalThreshold }) {
            lastSignal = .now
        }
        if !receivedAudio, let startTime, samples.contains(where: { abs($0) > 1e-5 }) {
            receivedAudio = true
            let elapsed = ContinuousClock.now - startTime
            log.info("First audio after \(Int(elapsed / .milliseconds(1))) ms from \(self.deviceName ?? "unknown", privacy: .public)")
        }
        onSamples?(samples)
    }

    private func observe(_ session: AVCaptureSession) {
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            MainActor.assumeIsolated {
                self?.sessionDidFail(session, error: error)
            }
        })
        if let device = input?.device { observeDisconnect(of: device) }
    }

    /// A disconnected device stops the session with a runtime error ("Recording
    /// Stopped"), which can arrive after the input was already replaced. Restart the
    /// session while the current device is connected; give up only if it fails again
    /// right after a restart.
    private func sessionDidFail(_ failedSession: AVCaptureSession, error: NSError?) {
        guard failedSession === session, !isPaused else { return }
        let description = "\(error?.localizedDescription ?? "unknown") (\(error?.code ?? 0))"
        if let device = input?.device, !device.isConnected {
            log.warning("Audio input error after disconnect: \(description, privacy: .public)")
            deviceDidDisconnect(device)
            return
        }
        if let lastRestart, ContinuousClock.now - lastRestart < .seconds(2) {
            fail("Audio input error: \(error?.localizedDescription ?? "unknown")")
            return
        }
        log.warning("Audio input error: \(description, privacy: .public); restarting capture")
        lastRestart = .now
        run(failedSession)
    }

    private func observeDisconnect(of device: AVCaptureDevice) {
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceDidDisconnect(device) }
        })
    }

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        stop()
        onFailure?(message)
    }

    enum RecorderError: LocalizedError {
        case noMicrophone
        case cannotUse(String)

        var errorDescription: String? {
            switch self {
            case .noMicrophone: "No microphone available"
            case .cannotUse(let name): "Cannot record from \(name)"
            }
        }
    }
}

private extension AVCaptureDevice {
    var isBluetooth: Bool {
        let transport = UInt32(bitPattern: transportType)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// Receives capture buffers (16 kHz mono Float32, as requested in `audioSettings`).
private final class SampleSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let handler: @Sendable ([Float]) -> Void

    init(handler: @escaping @Sendable ([Float]) -> Void) {
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        var bufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let data = bufferList.mBuffers.mData else { return }
        let count = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        handler(Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)))
    }
}
