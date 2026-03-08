import Foundation
import os
import SwiftUI
import WhisperKit

private let log = Logger(subsystem: "com.dictato.app", category: "AppState")

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var isTranscribing = false
    @Published var isModelLoaded = false
    @Published var modelLoadingProgress: String = "Starting..."
    @Published var transcriptionHistory: [Transcription] = []

    private var whisperKit: WhisperKit?
    private var audioSamples: [Float] = []

    private init() {
        log.info("AppState initialized")
        loadHistory()
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

    func initializeWhisperKit() async {
        log.info("Starting WhisperKit initialization")
        do {
            modelLoadingProgress = "Downloading model (0%)..."
            log.info("Downloading model...")
            let downloadBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Dictato/Models", isDirectory: true)
            try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
            log.info("Model download base: \(downloadBase.path())")

            let modelFolder = try await WhisperKit.download(
                variant: "openai_whisper-large-v3_turbo",
                downloadBase: downloadBase,
                progressCallback: { [weak self] progress in
                    let pct = Int(progress.fractionCompleted * 100)
                    Task { @MainActor [weak self] in
                        self?.modelLoadingProgress = "Downloading model (\(pct)%)..."
                    }
                }
            )
            log.info("Model downloaded to \(modelFolder.path)")

            modelLoadingProgress = "Compiling model (first launch is slow)..."
            log.info("Loading model into memory...")
            let kit = try await WhisperKit(
                modelFolder: modelFolder.path,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                verbose: true,
                logLevel: .info,
                prewarm: true,
                download: false
            )
            whisperKit = kit
            isModelLoaded = true
            modelLoadingProgress = "Ready"
            log.info("Model loaded successfully")
        } catch {
            modelLoadingProgress = "Model failed: \(error.localizedDescription)"
            log.error("WhisperKit init failed: \(error)")
        }
    }

    func toggleRecording() {
        if isRecording {
            log.info("Stopping recording")
            stopAndTranscribe()
        } else {
            log.info("Starting recording")
            startRecording()
        }
    }

    private func startRecording() {
        guard let whisperKit, isModelLoaded, !isTranscribing else {
            log.warning("Cannot start recording: model=\(self.isModelLoaded), transcribing=\(self.isTranscribing)")
            return
        }

        do {
            audioSamples = []
            try whisperKit.audioProcessor.startRecordingLive { [weak self] samples in
                DispatchQueue.main.async {
                    self?.audioSamples.append(contentsOf: samples)
                }
            }
            isRecording = true
            log.info("Recording started")
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
        guard let whisperKit, isRecording else { return }
        whisperKit.audioProcessor.pauseRecording()
        isRecording = false
        isPaused = true
        log.info("Recording paused")
    }

    private func resumeRecording() {
        guard let whisperKit, isPaused else { return }
        do {
            try whisperKit.audioProcessor.resumeRecordingLive { [weak self] samples in
                DispatchQueue.main.async {
                    self?.audioSamples.append(contentsOf: samples)
                }
            }
            isPaused = false
            isRecording = true
            log.info("Recording resumed")
        } catch {
            log.error("Failed to resume recording: \(error)")
        }
    }

    func discardRecording() {
        guard let whisperKit, isPaused else { return }
        whisperKit.audioProcessor.stopRecording()
        audioSamples = []
        isPaused = false
        isRecording = false
        log.info("Recording discarded")
    }

    private func stopAndTranscribe() {
        guard let whisperKit else { return }

        whisperKit.audioProcessor.stopRecording()
        isRecording = false
        isTranscribing = true

        let samples = audioSamples
        audioSamples = []
        log.info("Transcribing \(samples.count) samples")

        Task {
            do {
                let results = try await whisperKit.transcribe(
                    audioArray: samples,
                    decodeOptions: DecodingOptions(
                        wordTimestamps: false,
                        chunkingStrategy: .none
                    )
                )

                let text = results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined(separator: " ")

                log.info("Transcription result: \(text)")

                if !text.isEmpty {
                    let transcription = Transcription(text: text)
                    transcriptionHistory.insert(transcription, at: 0)
                    saveHistory()
                    PasteService.paste(text: text)
                }
            } catch {
                log.error("Transcription failed: \(error)")
            }

            isTranscribing = false
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
}
