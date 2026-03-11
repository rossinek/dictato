import AVFoundation
import Foundation
import os
import SwiftUI

private let log = Logger(subsystem: "com.dictato.app", category: "AppState")

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
    @Published var reTranscribingID: UUID?
    @Published var isFileTranscribing = false
    @Published var mainWindowTab: MainWindowTab = .history
    @Published var shouldOpenMainWindow = false
    @Published var audioLevels: [Float] = []

    private static let audioLevelBarCount = 48

    var selectedMode: TranscriptionMode {
        modes[min(selectedModeIndex, modes.count - 1)]
    }

    let modelManager = ModelManager()

    private var audioEngine: AVAudioEngine?
    private var audioSamples: [Float] = []
    private var failedSamples: [Float] = []
    private var transcriptionTask: Task<Void, Never>?

    private init() {
        log.info("AppState initialized")
        loadModes()
        loadHistory()
        cleanupOldRecordings()
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
            modelManager.preload(modes[index].transcriptionEngine)
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

        do {
            audioSamples = []
            audioLevels = []
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!

            let converter: AVAudioConverter?
            if recordingFormat.sampleRate != 16000 || recordingFormat.channelCount != 1 {
                converter = AVAudioConverter(from: recordingFormat, to: targetFormat)
            } else {
                converter = nil
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                let samples: [Float]
                if let converter {
                    let ratio = 16000.0 / recordingFormat.sampleRate
                    let targetFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                    guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCount) else { return }

                    var error: NSError?
                    var consumed = false
                    converter.convert(to: targetBuffer, error: &error) { _, outStatus in
                        if consumed {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        consumed = true
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    if error != nil { return }
                    samples = Array(UnsafeBufferPointer(start: targetBuffer.floatChannelData![0], count: Int(targetBuffer.frameLength)))
                } else {
                    samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                }

                // Compute RMS amplitude for this buffer
                let rms: Float = samples.isEmpty ? 0 : {
                    let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
                    return sqrt(sumOfSquares / Float(samples.count))
                }()

                DispatchQueue.main.async {
                    self?.audioSamples.append(contentsOf: samples)

                    // Update rolling audio levels for visualization
                    if let self {
                        self.audioLevels.append(rms)
                        if self.audioLevels.count > Self.audioLevelBarCount {
                            self.audioLevels.removeFirst(self.audioLevels.count - Self.audioLevelBarCount)
                        }
                    }
                }
            }

            try engine.start()
            audioEngine = engine
            isRecording = true
            log.info("Recording started")

            // Start loading the model in the background while recording
            modelManager.preload(selectedMode.transcriptionEngine)
        } catch {
            log.error("Failed to start recording: \(error)")
        }
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
        do {
            try engine.start()
            isPaused = false
            isRecording = true
            log.info("Recording resumed")
        } catch {
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
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
        modelManager.cancelPreload()
        modelManager.unloadCurrent()
        audioSamples = []
        isPaused = false
        isRecording = false
        log.info("Recording discarded")
    }

    func dismissError() {
        isError = false
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

    private func stopAndTranscribe() {
        guard let engine = audioEngine else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        isRecording = false
        isPaused = false
        isTranscribing = true

        let samples = audioSamples
        let mode = selectedMode
        audioSamples = []
        log.info("Transcribing \(samples.count) samples, engine: \(mode.transcriptionEngine.displayName), language: \(mode.language ?? "auto")")

        transcriptionTask = Task {
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
                    if mode.provider != .none, let model = mode.model, !trimmedPrompt.isEmpty {
                        isPostProcessing = true
                        do {
                            processedText = try await LLMService.postProcess(
                                provider: mode.provider,
                                model: model,
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
        if mode.provider != .none, let model = mode.model, !trimmedPrompt.isEmpty {
            if let processed = try? await LLMService.postProcess(
                provider: mode.provider,
                model: model,
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
                if mode.provider != .none, let model = mode.model, !trimmedPrompt.isEmpty {
                    do {
                        processedText = try await LLMService.postProcess(
                            provider: mode.provider,
                            model: model,
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
        let dir = appSupport.appendingPathComponent("Dictato/Recordings", isDirectory: true)
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
                if mode.provider != .none, let model = mode.model, !trimmedPrompt.isEmpty {
                    do {
                        processedText = try await LLMService.postProcess(
                            provider: mode.provider,
                            model: model,
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
        let dir = appSupport.appendingPathComponent("Dictato", isDirectory: true)
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
        let dir = appSupport.appendingPathComponent("Dictato", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("modes.json")
    }

    func saveModes() {
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
            log.debug("No modes file found, using defaults")
        }
        if modes.isEmpty {
            modes.append(TranscriptionMode.default)
            saveModes()
        }
        log.info("Modes loaded (\(self.modes.count) items)")
    }
}
