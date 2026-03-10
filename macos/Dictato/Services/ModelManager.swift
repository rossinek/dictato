import Foundation
import FluidAudio
import os
import WhisperKit

private let log = Logger(subsystem: "com.dictato.app", category: "ModelManager")

enum TranscriptionEngine: String, Codable, CaseIterable, Identifiable {
    case whisperKit
    case fluidAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperKit: "Whisper Large V3 Turbo"
        case .fluidAudio: "Parakeet TDT V3"
        }
    }

    var description: String {
        switch self {
        case .whisperKit: "OpenAI — via WhisperKit"
        case .fluidAudio: "Nvidia — via FluidAudio"
        }
    }
}

enum ModelStatus: Equatable {
    case notDownloaded
    case downloading(progress: Double?) // nil = indeterminate
    case compiling // CoreML compilation (first time only, cached after)
    case downloaded
    case loading
    case error(String)

    static func == (lhs: ModelStatus, rhs: ModelStatus) -> Bool {
        switch (lhs, rhs) {
        case (.notDownloaded, .notDownloaded): true
        case (.downloading(let a), .downloading(let b)): a == b
        case (.compiling, .compiling): true
        case (.downloaded, .downloaded): true
        case (.loading, .loading): true
        case (.error(let a), .error(let b)): a == b
        default: false
        }
    }

    var isDownloaded: Bool {
        switch self {
        case .downloaded, .loading: true
        default: false
        }
    }
}

@MainActor
class ModelManager: ObservableObject {
    @Published var statuses: [TranscriptionEngine: ModelStatus] = [:]

    private var whisperKit: WhisperKit?
    private var asrManager: AsrManager?
    private var loadedEngine: TranscriptionEngine?

    private var whisperModelFolder: URL?

    init() {
        checkExistingDownloads()
    }

    var hasAnyModelDownloaded: Bool {
        statuses.values.contains { $0.isDownloaded }
    }

    func isDownloaded(_ engine: TranscriptionEngine) -> Bool {
        statuses[engine]?.isDownloaded ?? false
    }

    func status(for engine: TranscriptionEngine) -> ModelStatus {
        statuses[engine] ?? .notDownloaded
    }

    // MARK: - Download

    func download(_ engine: TranscriptionEngine) async {
        guard statuses[engine] != .downloading(progress: nil) else { return }

        switch engine {
        case .whisperKit:
            await downloadWhisperKit()
        case .fluidAudio:
            await downloadFluidAudio()
        }
    }

    private func downloadWhisperKit() async {
        statuses[.whisperKit] = .downloading(progress: 0)
        do {
            let downloadBase = whisperKitDownloadBase
            setenv("HF_HOME", downloadBase.path, 1)
            try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)

            let modelFolder = try await WhisperKit.download(
                variant: "openai_whisper-large-v3_turbo",
                downloadBase: downloadBase,
                progressCallback: { [weak self] progress in
                    let pct = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        self?.statuses[.whisperKit] = .downloading(progress: pct)
                    }
                }
            )
            whisperModelFolder = modelFolder
            log.info("WhisperKit model downloaded to \(modelFolder.path)")

            // Prewarm: compile CoreML model so future loads are fast (~seconds instead of minutes)
            statuses[.whisperKit] = .compiling
            log.info("Prewarming WhisperKit model (CoreML compilation)...")
            let kit = try await WhisperKit(
                WhisperKitConfig(
                    downloadBase: downloadBase,
                    modelFolder: modelFolder.path,
                    tokenizerFolder: downloadBase,
                    computeOptions: ModelComputeOptions(
                        audioEncoderCompute: .cpuAndNeuralEngine,
                        textDecoderCompute: .cpuAndNeuralEngine
                    ),
                    verbose: true,
                    logLevel: .info,
                    prewarm: true,
                    download: false
                )
            )
            // Discard instance — we only needed the compilation cache
            _ = kit
            log.info("WhisperKit model prewarmed")

            statuses[.whisperKit] = .downloaded
        } catch {
            statuses[.whisperKit] = .error(error.localizedDescription)
            log.error("WhisperKit download failed: \(error)")
        }
    }

    private func downloadFluidAudio() async {
        statuses[.fluidAudio] = .downloading(progress: nil)
        do {
            let directory = fluidAudioModelDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // force: true ensures re-download even if partial/stale files exist
            _ = try await AsrModels.download(to: directory, force: true, version: .v3)
            statuses[.fluidAudio] = .downloaded
            log.info("FluidAudio model downloaded")
        } catch {
            statuses[.fluidAudio] = .error(error.localizedDescription)
            log.error("FluidAudio download failed: \(error)")
        }
    }

    // MARK: - Delete

    func delete(_ engine: TranscriptionEngine) {
        if loadedEngine == engine {
            unload(engine)
        }

        do {
            switch engine {
            case .whisperKit:
                let base = whisperKitDownloadBase
                if FileManager.default.fileExists(atPath: base.path) {
                    try FileManager.default.removeItem(at: base)
                }
                whisperModelFolder = nil
            case .fluidAudio:
                let dir = fluidAudioModelDirectory
                if FileManager.default.fileExists(atPath: dir.path) {
                    try FileManager.default.removeItem(at: dir)
                }
            }
            statuses[engine] = .notDownloaded
            log.info("Deleted model: \(engine.displayName)")
        } catch {
            log.error("Failed to delete model \(engine.displayName): \(error)")
            statuses[engine] = .error("Delete failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Load / Unload

    func transcribe(samples: [Float], engine: TranscriptionEngine, language: String?) async throws -> String {
        guard isDownloaded(engine) else {
            throw ModelError.notDownloaded(engine)
        }

        statuses[engine] = .loading
        defer {
            unload(engine)
            statuses[engine] = .downloaded
        }

        switch engine {
        case .whisperKit:
            return try await transcribeWithWhisperKit(samples: samples, language: language)
        case .fluidAudio:
            return try await transcribeWithFluidAudio(samples: samples)
        }
    }

    private func transcribeWithWhisperKit(samples: [Float], language: String?) async throws -> String {
        let downloadBase = whisperKitDownloadBase
        let modelFolder = whisperModelFolder ?? findWhisperModelFolder()

        guard let modelFolder else {
            throw ModelError.modelFilesNotFound(.whisperKit)
        }

        let kit = try await WhisperKit(
            WhisperKitConfig(
                downloadBase: downloadBase,
                modelFolder: modelFolder.path,
                tokenizerFolder: downloadBase,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                verbose: true,
                logLevel: .info,
                prewarm: true,
                download: false
            )
        )
        whisperKit = kit
        loadedEngine = .whisperKit

        let results = try await kit.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(
                language: language,
                wordTimestamps: false,
                chunkingStrategy: .none
            )
        )

        return results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
    }

    private func transcribeWithFluidAudio(samples: [Float]) async throws -> String {
        let directory = fluidAudioModelDirectory
        let models = try await AsrModels.load(from: directory, version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        asrManager = manager
        loadedEngine = .fluidAudio

        let result = try await manager.transcribe(samples, source: .system)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func unload(_ engine: TranscriptionEngine) {
        switch engine {
        case .whisperKit:
            whisperKit = nil
        case .fluidAudio:
            asrManager = nil
        }
        if loadedEngine == engine {
            loadedEngine = nil
        }
        log.info("Unloaded model: \(engine.displayName)")
    }

    // MARK: - Paths

    private var appSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Dictato", isDirectory: true)
    }

    private var whisperKitDownloadBase: URL {
        appSupportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    private var fluidAudioModelDirectory: URL {
        appSupportDirectory.appendingPathComponent("FluidAudio", isDirectory: true)
    }

    // MARK: - Checks

    private func checkExistingDownloads() {
        // WhisperKit: check if model folder exists
        if findWhisperModelFolder() != nil {
            statuses[.whisperKit] = .downloaded
            log.info("Found existing WhisperKit model")
        } else {
            statuses[.whisperKit] = .notDownloaded
        }

        // FluidAudio: use library's built-in check
        let fluidDir = fluidAudioModelDirectory
        if AsrModels.modelsExist(at: fluidDir, version: .v3) {
            statuses[.fluidAudio] = .downloaded
            log.info("Found existing FluidAudio model")
        } else {
            statuses[.fluidAudio] = .notDownloaded
        }
    }

    private func findWhisperModelFolder() -> URL? {
        if let cached = whisperModelFolder, FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let base = whisperKitDownloadBase
        // WhisperKit downloads to: base/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo
        let expected = base
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo")
        if FileManager.default.fileExists(atPath: expected.path) {
            whisperModelFolder = expected
            return expected
        }
        return nil
    }
}

enum ModelError: LocalizedError {
    case notDownloaded(TranscriptionEngine)
    case modelFilesNotFound(TranscriptionEngine)

    var errorDescription: String? {
        switch self {
        case .notDownloaded(let engine):
            "\(engine.displayName) is not downloaded. Please download it from Settings."
        case .modelFilesNotFound(let engine):
            "\(engine.displayName) model files not found on disk."
        }
    }
}
