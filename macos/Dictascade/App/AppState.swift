@preconcurrency import AVFoundation
import Foundation
import os
import SwiftUI

private let log = Logger(subsystem: "com.dictascade.app", category: "AppState")

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var isTranscribing = false
    @Published var isModelLoading = false
    @Published var transcriptionHistory: [Transcription] = []
    @Published var modes: [TranscriptionMode] = []
    @Published var selectedModeIndex: Int = 0
    @Published var isPostProcessing = false
    @Published var isError = false
    @Published var errorMessage = ""
    @Published var reTranscribingID: UUID?
    @Published var isFileTranscribing = false
    @Published var mainWindowTab: MainWindowTab = .history
    @Published var shouldOpenMainWindow = false

    var selectedMode: TranscriptionMode {
        modes[min(selectedModeIndex, modes.count - 1)]
    }

    let modelManager = ModelManager()
    let audioLevelMeter = AudioLevelMeter()

    private var audioEngine: AVAudioEngine?
    private var audioSamples: [Float] = []
    private var failedSamples: [Float] = []
    private var transcriptionTask: Task<Void, Never>?
    private let audioSampleConverter = AudioSampleConverter()
    private var audioCaptureSessionID: UUID?
    private var audioConfigurationObserver: NSObjectProtocol?
    private var audioRestartTask: Task<Void, Never>?
    private var isAudioTapInstalled = false
    private var audioConfigurationNeedsRefresh = false

    private let modeSync = ModeSync.shared

    private init() {
        log.info("AppState initialized")
        loadModes()
        setupModeSync()
        loadHistory()
        cleanupOldRecordings()
    }

    private func setupModeSync() {
        // Save engine map from current local modes before any sync
        modeSync.saveEngineMap(modes)

        modeSync.onRemoteChange = { [weak self] sharedModes in
            guard let self else { return }
            // Accept remote as truth, apply local engine map
            self.modes = self.modeSync.applyEngineMap(sharedModes)
            self.saveModesLocal()
            // Do NOT push back — avoid ping-pong
            if self.selectedModeIndex >= self.modes.count {
                self.selectedModeIndex = max(0, self.modes.count - 1)
            }
            if self.modes.isEmpty {
                self.modes.append(TranscriptionMode.default)
                self.saveModesLocal()
                self.modeSync.pushModes(self.modes)
            }
        }

        modeSync.onVocabularyChange = { [weak self] remoteVocab in
            guard let self else { return }
            UserDefaults.standard.set(remoteVocab, forKey: "vocabulary")
            self.modelManager.configureVocabulary(remoteVocab)
        }

        // Initial sync
        if let remote = modeSync.fetchRemote() {
            if remote.deviceID != modeSync.deviceID {
                // Accept remote modes
                modes = modeSync.applyEngineMap(remote.modes)
                saveModesLocal()
                if selectedModeIndex >= modes.count {
                    selectedModeIndex = max(0, modes.count - 1)
                }
            }
            // If own device: no-op, already up to date
        } else {
            // No remote data — push local modes
            modeSync.pushModes(modes)
        }

        if modes.isEmpty {
            modes.append(TranscriptionMode.default)
            saveModes()
        }

        // Initial vocabulary sync
        if let remoteVocab = modeSync.fetchRemoteVocabulary() {
            let localVocab = UserDefaults.standard.string(forKey: "vocabulary") ?? ""
            if localVocab.isEmpty && !remoteVocab.isEmpty {
                UserDefaults.standard.set(remoteVocab, forKey: "vocabulary")
            } else if !localVocab.isEmpty {
                modeSync.pushVocabulary(localVocab)
            }
        } else {
            let localVocab = UserDefaults.standard.string(forKey: "vocabulary") ?? ""
            if !localVocab.isEmpty {
                modeSync.pushVocabulary(localVocab)
            }
        }

        modeSync.start()
    }

    #if DEBUG
    static func preview() -> AppState {
        let state = AppState()
        state.modes = [
            .default,
            TranscriptionMode(id: UUID(), name: "Email", language: "en", prompt: "Fix grammar"),
        ]
        // Create a dummy audio file so hasAudio is true for preview
        let dummyFileName = "preview-audio.wav"
        let dummyURL = state.recordingsDirectoryURL.appendingPathComponent(dummyFileName)
        if !FileManager.default.fileExists(atPath: dummyURL.path) {
            let header = Data([
                0x52,0x49,0x46,0x46, 0x24,0x00,0x00,0x00, 0x57,0x41,0x56,0x45,
                0x66,0x6D,0x74,0x20, 0x10,0x00,0x00,0x00, 0x01,0x00,0x01,0x00,
                0x80,0x3E,0x00,0x00, 0x00,0x7D,0x00,0x00, 0x02,0x00,0x10,0x00,
                0x64,0x61,0x74,0x61, 0x00,0x00,0x00,0x00,
            ])
            try? header.write(to: dummyURL)
        }

        state.transcriptionHistory = [
            Transcription(
                text: "Hey, remind me to pick up groceries on the way home tonight. Also, can you check if the dry cleaning is ready?",
                postProcessedText: "Remind me to pick up groceries on the way home tonight. Also, check if the dry cleaning is ready.",
                modeName: "Default",
                audioFileName: dummyFileName
            ),
            Transcription(
                text: "The quarterly report shows a 15% increase in revenue compared to last year, driven primarily by expansion into new markets.",
                modeName: "Email"
            ),
            Transcription(text: "Quick test recording", modeName: "Default"),
        ]
        return state
    }
    #endif

    func selectMode(index: Int) {
        guard index >= 0, index < modes.count else { return }
        selectedModeIndex = index
        log.info("Selected mode: \(self.modes[index].name)")

        // If recording, preload the new mode's engine (cancels previous preload)
        if isRecording || isPaused {
            if let engine = resolveEngine(for: modes[index]) {
                modelManager.preload(engine)
            }
        }
    }

    func requestPermissions() async {
        log.info("Checking permissions...")

        let micGranted = await PermissionsService.requestMicrophoneAccess()
        log.info("Microphone access: \(micGranted)")

        if !PermissionsService.hasAccessibilityAccess {
            _ = await PermissionsService.requestAccessibilityAccess()
            log.info("Accessibility access requested")
        }
    }

    /// Whether the current mode's transcription engine is downloaded and ready
    var isEngineAvailable: Bool {
        modelManager.isDownloaded(selectedMode.transcriptionEngine)
    }

    /// Returns the mode's engine if downloaded, otherwise any downloaded engine as fallback, or nil if none available.
    func resolveEngine(for mode: TranscriptionMode) -> TranscriptionEngine? {
        if modelManager.isDownloaded(mode.transcriptionEngine) {
            return mode.transcriptionEngine
        }
        return TranscriptionEngine.allCases.first { modelManager.isDownloaded($0) }
    }

    func toggleRecording() {
        if isPaused {
            log.info("Resuming recording")
            resumeRecording()
        } else if isRecording {
            log.info("Stopping recording")
            stopAndTranscribe()
        } else {
            log.info("Starting recording")
            startRecording()
        }
    }

    // MARK: - Recording (AVAudioEngine)

    private func startRecording() {
        guard !isTranscribing else {
            log.warning("Cannot start recording: transcribing=\(self.isTranscribing)")
            return
        }

        guard let resolvedEngine = resolveEngine(for: selectedMode) else {
            log.error("No transcription model downloaded")
            errorMessage = "No model downloaded"
            isError = true
            return
        }

        do {
            audioSamples = []
            audioLevelMeter.reset()
            let engine = AVAudioEngine()
            let sessionID = UUID()
            audioCaptureSessionID = sessionID
            audioSampleConverter.reset()
            installAudioInputTap(on: engine, sessionID: sessionID)
            observeAudioConfigurationChanges(for: engine)

            audioEngine = engine
            isRecording = true
            engine.prepare()
            try engine.start()
            logInputFormat(engine, message: "Recording started")

            // Start loading the model in the background while recording
            modelManager.preload(resolvedEngine)
        } catch {
            if let engine = audioEngine {
                failAudioCapture(
                    engine,
                    message: "Could not start audio input: \(error.localizedDescription)"
                )
            } else {
                isRecording = false
                errorMessage = "Could not start audio input: \(error.localizedDescription)"
                isError = true
            }
            log.error("Failed to start recording: \(error)")
        }
    }

    private func installAudioInputTap(on engine: AVAudioEngine, sessionID: UUID) {
        let inputNode = engine.inputNode
        let sampleConverter = audioSampleConverter

        // Passing nil lets the tap follow the input node's current hardware
        // format instead of pinning the pre-HFP Bluetooth format.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let samples = sampleConverter.convert(buffer), !samples.isEmpty else { return }

            let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
            let rms = sqrt(sumOfSquares / Float(samples.count))

            DispatchQueue.main.async { [weak self] in
                guard let self, self.audioCaptureSessionID == sessionID else { return }

                self.audioSamples.append(contentsOf: samples)
                self.audioLevelMeter.update(rms: rms)
            }
        }
        isAudioTapInstalled = true
    }

    private func observeAudioConfigurationChanges(for engine: AVAudioEngine) {
        removeAudioConfigurationObserver()
        audioConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            guard let engine else { return }
            Task { @MainActor [weak self] in
                self?.audioConfigurationDidChange(for: engine)
            }
        }
    }

    private func audioConfigurationDidChange(for engine: AVAudioEngine) {
        guard audioEngine === engine, isRecording || isPaused else { return }

        audioConfigurationNeedsRefresh = true
        logInputFormat(engine, message: "Audio input configuration changed")

        // A paused engine is refreshed immediately before resume.
        guard isRecording else { return }

        audioRestartTask?.cancel()
        audioRestartTask = Task { @MainActor [weak self, weak engine] in
            // Leave the notification callback before touching the engine. Apple
            // warns that synchronous teardown from that callback can deadlock.
            await Task.yield()
            guard !Task.isCancelled, let self, let engine,
                  self.audioEngine === engine, self.isRecording else { return }

            do {
                try self.refreshAudioCapture(engine)
                self.logInputFormat(engine, message: "Audio input restarted")
            } catch {
                self.failAudioCapture(
                    engine,
                    message: "Audio input changed and could not be restarted: \(error.localizedDescription)"
                )
                log.error("Failed to restart audio after configuration change: \(error)")
            }
        }
    }

    private func refreshAudioCapture(_ engine: AVAudioEngine) throws {
        engine.stop()
        if isAudioTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isAudioTapInstalled = false
        }

        audioSampleConverter.reset()
        guard let sessionID = audioCaptureSessionID else { return }
        installAudioInputTap(on: engine, sessionID: sessionID)
        engine.prepare()
        try engine.start()
        audioConfigurationNeedsRefresh = false
    }

    private func stopAudioCapture(_ engine: AVAudioEngine) {
        audioRestartTask?.cancel()
        audioRestartTask = nil
        removeAudioConfigurationObserver()
        audioCaptureSessionID = nil
        audioConfigurationNeedsRefresh = false

        if isAudioTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isAudioTapInstalled = false
        }
        engine.stop()
        audioSampleConverter.reset()

        if audioEngine === engine {
            audioEngine = nil
        }
    }

    private func failAudioCapture(_ engine: AVAudioEngine, message: String) {
        let capturedSamples = audioSamples
        stopAudioCapture(engine)

        failedSamples = capturedSamples
        audioSamples = []
        isRecording = false
        isPaused = false
        errorMessage = message
        isError = true
    }

    private func removeAudioConfigurationObserver() {
        if let audioConfigurationObserver {
            NotificationCenter.default.removeObserver(audioConfigurationObserver)
            self.audioConfigurationObserver = nil
        }
    }

    private func logInputFormat(_ engine: AVAudioEngine, message: String) {
        let format = engine.inputNode.outputFormat(forBus: 0)
        log.info(
            "\(message, privacy: .public): \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) channel(s)"
        )
    }

    func togglePause() {
        guard isRecording || isPaused else { return }
        if isPaused {
            resumeRecording()
        } else {
            pauseRecording()
        }
    }

    private func pauseRecording() {
        guard audioEngine != nil, isRecording else { return }
        audioEngine?.pause()
        isRecording = false
        isPaused = true
        log.info("Recording paused")
    }

    private func resumeRecording() {
        guard let engine = audioEngine, isPaused else { return }
        // Mark the capture active before starting the engine so a Bluetooth
        // configuration notification emitted by start() schedules recovery.
        isPaused = false
        isRecording = true
        do {
            if audioConfigurationNeedsRefresh {
                try refreshAudioCapture(engine)
            } else {
                engine.prepare()
                try engine.start()
            }
            logInputFormat(engine, message: "Recording resumed")
        } catch {
            failAudioCapture(
                engine,
                message: "Could not resume audio input: \(error.localizedDescription)"
            )
            log.error("Failed to resume recording: \(error)")
        }
    }

    func cancelTranscription() {
        guard isTranscribing || isPostProcessing else { return }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
        isModelLoading = false
        isPostProcessing = false
        log.info("Transcription cancelled")
    }

    func discardRecording() {
        guard isPaused || isRecording else { return }
        if let engine = audioEngine {
            stopAudioCapture(engine)
        }
        modelManager.cancelPreload()
        modelManager.unloadCurrent()
        audioSamples = []
        isPaused = false
        isRecording = false
        log.info("Recording discarded")
    }

    var hasFailedRecording: Bool { !failedSamples.isEmpty }

    func dismissError() {
        isError = false
        errorMessage = ""
        failedSamples = []
        log.info("Error dismissed")
    }

    func saveFailedRecording() {
        guard !failedSamples.isEmpty else { return }
        let samples = failedSamples

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.wav]
        savePanel.nameFieldStringValue = "recording-\(Int(Date().timeIntervalSince1970)).wav"

        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        let sampleRate: Double = 16000
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            log.error("Failed to create audio buffer")
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)

        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            log.info("Recording saved to \(url.path)")
        } catch {
            log.error("Failed to save recording: \(error)")
        }

        dismissError()
    }

    /// Stop recording, transcribe, and return the result text. For use by AppIntents.
    func stopAndTranscribeAsync() async -> String {
        guard let engine = audioEngine else { return "" }

        stopAudioCapture(engine)
        isRecording = false
        isPaused = false
        isTranscribing = true

        let samples = audioSamples
        let mode = selectedMode
        audioSamples = []

        defer {
            isTranscribing = false
            isPostProcessing = false
            modelManager.unloadCurrent()
        }

        do {
            isModelLoading = true
            try await modelManager.awaitLoad()
            isModelLoading = false

            let text = try await modelManager.transcribeLoaded(
                samples: samples, language: mode.language
            )
            guard !text.isEmpty else { return "" }

            isTranscribing = false
            var finalText = text
            let trimmedPrompt = mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if mode.provider != .none, (mode.provider == .appleIntelligence || mode.model != nil), !trimmedPrompt.isEmpty {
                isPostProcessing = true
                if let processed = try? await LLMService.postProcess(
                    provider: mode.provider, model: mode.model,
                    systemPrompt: trimmedPrompt, userMessage: text
                ) {
                    finalText = processed
                }
                isPostProcessing = false
            }

            let audioFileName = saveAudioFile(samples: samples, id: nil)
            let transcription = Transcription(
                text: text,
                postProcessedText: finalText != text ? finalText : nil,
                modeName: mode.name,
                audioFileName: audioFileName
            )
            transcriptionHistory.insert(transcription, at: 0)
            cleanupOldRecordings()
            saveHistory()
            PasteService.paste(text: finalText)
            return finalText
        } catch {
            log.error("Transcription failed: \(error)")
            isModelLoading = false
            return ""
        }
    }

    private func stopAndTranscribe() {
        guard let engine = audioEngine else { return }

        stopAudioCapture(engine)
        isRecording = false
        isPaused = false
        isTranscribing = true

        let samples = audioSamples
        let mode = selectedMode
        audioSamples = []
        log.info("Transcribing \(samples.count) samples, engine: \(mode.transcriptionEngine.displayName), language: \(mode.language ?? "auto")")

        transcriptionTask = Task {
            // Drop the completed task immediately so it cannot retain the
            // previous recording's sample buffer until the next transcription.
            defer { transcriptionTask = nil }

            do {
                // Wait for model to finish loading (started when recording began)
                isModelLoading = true
                try await modelManager.awaitLoad()
                isModelLoading = false

                let text = try await modelManager.transcribeLoaded(
                    samples: samples,
                    language: mode.language
                )

                // Unload model to free RAM
                modelManager.unloadCurrent()

                log.info("Transcription result: \(text)")

                if !text.isEmpty {
                    isTranscribing = false

                    var processedText: String?
                    let trimmedPrompt = mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if mode.provider != .none, (mode.provider == .appleIntelligence || mode.model != nil), !trimmedPrompt.isEmpty {
                        isPostProcessing = true
                        do {
                            processedText = try await LLMService.postProcess(
                                provider: mode.provider,
                                model: mode.model,
                                systemPrompt: trimmedPrompt,
                                userMessage: text
                            )
                            log.info("Post-processing result: \(processedText ?? "")")
                        } catch {
                            log.error("Post-processing failed: \(error)")
                        }
                        isPostProcessing = false
                    }

                    let audioFileName = self.saveAudioFile(samples: samples, id: nil)
                    let transcription = Transcription(
                        text: text,
                        postProcessedText: processedText,
                        modeName: mode.name,
                        audioFileName: audioFileName
                    )
                    transcriptionHistory.insert(transcription, at: 0)
                    cleanupOldRecordings()
                    saveHistory()
                    PasteService.paste(text: processedText ?? text)
                    NSSound(named: "Funk")?.play()
                } else {
                    modelManager.unloadCurrent()
                    failedSamples = samples
                    isTranscribing = false
                    isError = true
                    NSSound(named: "Sosumi")?.play()
                    log.warning("Transcription returned empty text")
                }
            } catch {
                log.error("Transcription failed: \(error)")
                modelManager.unloadCurrent()
                failedSamples = samples
                isTranscribing = false
                isModelLoading = false
                isPostProcessing = false
                isError = true
                NSSound(named: "Sosumi")?.play()
                return
            }

            isTranscribing = false
            isPostProcessing = false
        }
    }

    // MARK: - File Transcription

    private func loadAudioFromFile(url: URL) -> [Float]? {
        do {
            let sourceFile = try AVAudioFile(forReading: url)
            let sourceFormat = sourceFile.processingFormat
            let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!

            let frameCount = AVAudioFrameCount(sourceFile.length)
            guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return nil }
            try sourceFile.read(into: sourceBuffer)

            if sourceFormat.sampleRate == 16000 && sourceFormat.channelCount == 1 {
                return Array(UnsafeBufferPointer(start: sourceBuffer.floatChannelData![0], count: Int(sourceBuffer.frameLength)))
            }

            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                log.error("Cannot create audio converter")
                return nil
            }
            let ratio = 16000.0 / sourceFormat.sampleRate
            let targetFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
            guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCount) else { return nil }

            var error: NSError?
            converter.convert(to: targetBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            if let error { log.error("Audio conversion failed: \(error)"); return nil }

            return Array(UnsafeBufferPointer(start: targetBuffer.floatChannelData![0], count: Int(targetBuffer.frameLength)))
        } catch {
            log.error("Failed to load audio file: \(error)")
            return nil
        }
    }

    /// Transcribe an audio file and return the result text (for AppIntents / Shortcuts).
    func transcribeFileAsync(url: URL, mode: TranscriptionMode) async throws -> String {
        guard modelManager.isDownloaded(mode.transcriptionEngine) else {
            throw ModelError.notDownloaded(mode.transcriptionEngine)
        }
        guard let samples = loadAudioFromFile(url: url) else {
            throw TranscriptionError.fileLoadFailed
        }

        modelManager.preload(mode.transcriptionEngine)
        try await modelManager.awaitLoad()
        let text = try await modelManager.transcribeLoaded(
            samples: samples,
            language: mode.language
        )
        modelManager.unloadCurrent()

        guard !text.isEmpty else {
            throw TranscriptionError.emptyResult
        }

        var finalText = text
        let trimmedPrompt = mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode.provider != .none, (mode.provider == .appleIntelligence || mode.model != nil), !trimmedPrompt.isEmpty {
            if let processed = try? await LLMService.postProcess(
                provider: mode.provider,
                model: mode.model,
                systemPrompt: trimmedPrompt,
                userMessage: text
            ) {
                finalText = processed
            }
        }

        let transcription = Transcription(
            text: text,
            postProcessedText: finalText != text ? finalText : nil,
            modeName: mode.name
        )
        transcriptionHistory.insert(transcription, at: 0)
        saveHistory()

        return finalText
    }

    enum TranscriptionError: LocalizedError {
        case fileLoadFailed, emptyResult

        var errorDescription: String? {
            switch self {
            case .fileLoadFailed: return "Failed to load audio file"
            case .emptyResult: return "Transcription returned empty text"
            }
        }
    }

    func transcribeFile(url: URL, mode: TranscriptionMode, completion: @escaping () -> Void) {
        guard !isRecording, !isTranscribing, !isFileTranscribing else { return }
        guard modelManager.isDownloaded(mode.transcriptionEngine) else {
            log.error("Engine not downloaded: \(mode.transcriptionEngine.displayName)")
            return
        }
        guard let samples = loadAudioFromFile(url: url) else {
            log.error("Failed to load audio from file: \(url.path)")
            return
        }

        isFileTranscribing = true
        log.info("Transcribing file: \(url.lastPathComponent), \(samples.count) samples")

        Task {
            defer {
                isFileTranscribing = false
                completion()
            }

            do {
                modelManager.preload(mode.transcriptionEngine)
                try await modelManager.awaitLoad()
                let text = try await modelManager.transcribeLoaded(
                    samples: samples,
                    language: mode.language
                )
                modelManager.unloadCurrent()

                guard !text.isEmpty else {
                    log.warning("File transcription returned empty text")
                    return
                }

                var processedText: String?
                let trimmedPrompt = mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if mode.provider != .none, (mode.provider == .appleIntelligence || mode.model != nil), !trimmedPrompt.isEmpty {
                    do {
                        processedText = try await LLMService.postProcess(
                            provider: mode.provider,
                            model: mode.model,
                            systemPrompt: trimmedPrompt,
                            userMessage: text
                        )
                    } catch {
                        log.error("File transcription post-processing failed: \(error)")
                    }
                }

                let transcription = Transcription(
                    text: text,
                    postProcessedText: processedText,
                    modeName: mode.name
                )
                transcriptionHistory.insert(transcription, at: 0)
                saveHistory()
                log.info("File transcription complete: \(text.prefix(50))...")
            } catch {
                modelManager.unloadCurrent()
                log.error("File transcription failed: \(error)")
            }
        }
    }

    // MARK: - Audio Caching

    var recordingsDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Dictascade/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func audioFileURL(for transcription: Transcription) -> URL? {
        guard let fileName = transcription.audioFileName else { return nil }
        let url = recordingsDirectoryURL.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func saveAudioFile(samples: [Float], id: UUID?) -> String? {
        let fileName = "\((id ?? UUID()).uuidString).wav"
        let url = recordingsDirectoryURL.appendingPathComponent(fileName)

        let sampleRate: Double = 16000
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            log.error("Failed to create audio buffer for caching")
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)

        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            log.info("Audio cached: \(fileName)")
            return fileName
        } catch {
            log.error("Failed to cache audio: \(error)")
            return nil
        }
    }

    private func loadAudioSamples(fileName: String) -> [Float]? {
        let url = recordingsDirectoryURL.appendingPathComponent(fileName)
        do {
            let file = try AVAudioFile(forReading: url)
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
                return nil
            }
            try file.read(into: buffer)
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        } catch {
            log.error("Failed to load audio: \(error)")
            return nil
        }
    }

    private func cleanupOldRecordings() {
        let maxCached = 5
        let indicesWithAudio = transcriptionHistory.indices.filter { transcriptionHistory[$0].audioFileName != nil }

        guard indicesWithAudio.count > maxCached else { return }

        let toRemove = indicesWithAudio.suffix(from: maxCached)
        for i in toRemove {
            if let fileName = transcriptionHistory[i].audioFileName {
                let url = recordingsDirectoryURL.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: url)
                log.info("Removed old audio: \(fileName)")
            }
            transcriptionHistory[i].audioFileName = nil
        }
        saveHistory()
    }

    func deleteTranscription(id: UUID) {
        guard let index = transcriptionHistory.firstIndex(where: { $0.id == id }) else { return }
        if let fileName = transcriptionHistory[index].audioFileName {
            let url = recordingsDirectoryURL.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: url)
        }
        transcriptionHistory.remove(at: index)
        saveHistory()
        log.info("Deleted transcription")
    }

    func reTranscribe(transcriptionID: UUID, withMode mode: TranscriptionMode) {
        guard !isRecording, !isTranscribing, !isPaused else { return }
        guard modelManager.isDownloaded(mode.transcriptionEngine) else {
            log.error("Engine not downloaded for re-transcription: \(mode.transcriptionEngine.displayName)")
            return
        }
        guard let index = transcriptionHistory.firstIndex(where: { $0.id == transcriptionID }),
              let audioFileName = transcriptionHistory[index].audioFileName,
              let samples = loadAudioSamples(fileName: audioFileName) else { return }

        reTranscribingID = transcriptionID

        Task {
            defer {
                reTranscribingID = nil
            }

            do {
                modelManager.preload(mode.transcriptionEngine)
                try await modelManager.awaitLoad()
                let text = try await modelManager.transcribeLoaded(
                    samples: samples,
                    language: mode.language
                )
                modelManager.unloadCurrent()

                guard !text.isEmpty else { return }

                var processedText: String?
                let trimmedPrompt = mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if mode.provider != .none, (mode.provider == .appleIntelligence || mode.model != nil), !trimmedPrompt.isEmpty {
                    do {
                        processedText = try await LLMService.postProcess(
                            provider: mode.provider,
                            model: mode.model,
                            systemPrompt: trimmedPrompt,
                            userMessage: text
                        )
                    } catch {
                        log.error("Re-transcription post-processing failed: \(error)")
                    }
                }

                transcriptionHistory[index].text = text
                transcriptionHistory[index].postProcessedText = processedText
                transcriptionHistory[index].modeName = mode.name
                saveHistory()
                log.info("Re-transcribed with mode: \(mode.name)")
            } catch {
                modelManager.unloadCurrent()
                log.error("Re-transcription failed: \(error)")
            }
        }
    }

    // MARK: - History Persistence

    private var historyFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Dictascade", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private func saveHistory() {
        do {
            let data = try JSONEncoder().encode(transcriptionHistory)
            try data.write(to: historyFileURL)
            log.info("History saved (\(self.transcriptionHistory.count) items)")
        } catch {
            log.error("Failed to save history: \(error)")
        }
    }

    private func loadHistory() {
        do {
            let data = try Data(contentsOf: historyFileURL)
            transcriptionHistory = try JSONDecoder().decode([Transcription].self, from: data)
            log.info("History loaded (\(self.transcriptionHistory.count) items)")
        } catch {
            log.debug("No history file found")
        }
    }

    // MARK: - Mode Persistence

    private var modesFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Dictascade", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("modes.json")
    }

    func saveModes() {
        saveModesLocal()
        modeSync.saveEngineMap(modes)
        modeSync.pushModes(modes)
    }

    private func saveModesLocal() {
        do {
            let data = try JSONEncoder().encode(modes)
            try data.write(to: modesFileURL)
            log.info("Modes saved (\(self.modes.count) items)")
        } catch {
            log.error("Failed to save modes: \(error)")
        }
    }

    private func loadModes() {
        do {
            let data = try Data(contentsOf: modesFileURL)
            modes = try JSONDecoder().decode([TranscriptionMode].self, from: data)
        } catch {
            log.debug("No modes file found")
        }
        log.info("Modes loaded (\(self.modes.count) items)")
    }
}
