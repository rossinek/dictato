import Foundation
import FluidAudio
import os
import WhisperKit

private let log = Logger(subsystem: "com.dictascade.app", category: "ModelManager")

enum TranscriptionEngine: String, Codable, CaseIterable, Identifiable {
    case fluidAudio
    case whisperKit

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

    var keepLoaded: Bool {
        switch self {
        case .whisperKit: false
        case .fluidAudio: true
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
    private var ctcModels: CtcModels?

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

    // MARK: - Preload / Await / Transcribe / Unload

    private var preloadTask: Task<Void, Error>?
    private var preloadingEngine: TranscriptionEngine?

    /// Start loading a model in the background. Cancels any in-progress preload.
    func preload(_ engine: TranscriptionEngine) {
        // Already loaded — nothing to do
        if loadedEngine == engine {
            log.info("Preload: \(engine.displayName) already loaded, skipping")
            return
        }

        // Cancel in-progress preload if it's for a different engine
        if let current = preloadingEngine, current != engine {
            log.info("Preload: cancelling in-progress load of \(current.displayName)")
            preloadTask?.cancel()
            preloadTask = nil
            preloadingEngine = nil
            // Unload the previous engine if it finished loading
            if loadedEngine == current {
                unload(current)
            }
        }

        // Already preloading this engine — let it continue
        if preloadingEngine == engine {
            log.info("Preload: \(engine.displayName) already loading, continuing")
            return
        }

        guard isDownloaded(engine) else {
            log.warning("Preload: \(engine.displayName) not downloaded, skipping")
            return
        }

        preloadingEngine = engine
        statuses[engine] = .loading
        log.info("Preload: starting load of \(engine.displayName)")

        preloadTask = Task {
            try await loadEngine(engine)
            try Task.checkCancellation()
            await MainActor.run {
                self.loadedEngine = engine
                self.preloadingEngine = nil
                self.statuses[engine] = .downloaded
                log.info("Preload: \(engine.displayName) loaded successfully")
            }
        }
    }

    /// Wait for the current preload to finish. Call after recording stops.
    func awaitLoad() async throws {
        guard let task = preloadTask else {
            // No preload in progress — check if already loaded
            if loadedEngine != nil { return }
            throw ModelError.noModelLoading
        }
        log.info("Awaiting model load...")
        try await task.value
    }

    /// Transcribe with whatever engine is currently loaded.
    func transcribeLoaded(samples: [Float], language: String?) async throws -> String {
        guard let engine = loadedEngine else {
            throw ModelError.noModelLoaded
        }
        log.info("Transcribing \(samples.count) samples with \(engine.displayName)")

        switch engine {
        case .whisperKit:
            return try await transcribeWithWhisperKit(samples: samples, language: language)
        case .fluidAudio:
            return try await transcribeWithFluidAudio(samples: samples)
        }
    }

    /// Unload the current engine, freeing RAM. Engines with keepLoaded skip unloading.
    func unloadCurrent() {
        guard let engine = loadedEngine, !engine.keepLoaded else { return }
        unload(engine)
    }

    /// Cancel any in-progress preload without unloading.
    func cancelPreload() {
        if let engine = preloadingEngine {
            log.info("Cancelling preload of \(engine.displayName)")
            preloadTask?.cancel()
            preloadTask = nil
            preloadingEngine = nil
            statuses[engine] = .downloaded
        }
    }

    // MARK: - Internal Load/Unload

    private func loadEngine(_ engine: TranscriptionEngine) async throws {
        switch engine {
        case .whisperKit:
            try await loadWhisperKit()
        case .fluidAudio:
            try await loadFluidAudio()
        }
    }

    private func loadWhisperKit() async throws {
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
    }

    private func loadFluidAudio() async throws {
        let directory = fluidAudioModelDirectory
        let models = try await AsrModels.load(from: directory, version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        asrManager = manager

        // Apply vocabulary boosting if configured
        let vocab = UserDefaults.standard.string(forKey: "vocabulary") ?? ""
        if !vocab.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await MainActor.run {
                configureVocabulary(vocab)
            }
        }
    }

    private func transcribeWithWhisperKit(samples: [Float], language: String?) async throws -> String {
        guard let kit = whisperKit else {
            throw ModelError.noModelLoaded
        }

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
        guard let manager = asrManager else {
            throw ModelError.noModelLoaded
        }

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
        log.info("Unloaded: \(engine.displayName)")
    }

    // MARK: - Vocabulary Boosting

    func configureVocabulary(_ text: String) {
        guard let manager = asrManager else {
            log.info("Vocabulary: no ASR manager loaded, skipping")
            return
        }

        let terms = parseVocabularyTerms(text)
        guard !terms.isEmpty else {
            manager.disableVocabularyBoosting()
            log.info("Vocabulary: disabled (no terms)")
            return
        }

        Task {
            do {
                if ctcModels == nil {
                    log.info("Vocabulary: downloading CTC models...")
                    ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                    fixCtcConfigJson()
                    log.info("Vocabulary: CTC models ready")
                }

                guard let ctcModels else { return }

                let tokenizer = try await CtcTokenizer.load(
                    from: CtcModels.defaultCacheDirectory(for: .ctc110m)
                )
                let tokenizedTerms = terms.compactMap { term -> CustomVocabularyTerm? in
                    let ids = tokenizer.encode(term.text)
                    guard !ids.isEmpty else { return nil }
                    return CustomVocabularyTerm(
                        text: term.text,
                        weight: term.weight,
                        aliases: term.aliases,
                        ctcTokenIds: ids
                    )
                }

                let vocab = CustomVocabularyContext(terms: tokenizedTerms, minSimilarity: 0.8)
                try await manager.configureVocabularyBoosting(
                    vocabulary: vocab,
                    ctcModels: ctcModels
                )
                log.info("Vocabulary: configured \(tokenizedTerms.count) terms")
            } catch {
                log.error("Vocabulary: configuration failed: \(error)")
            }
        }
    }

    private func parseVocabularyTerms(_ text: String) -> [CustomVocabularyTerm] {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line in
                if let colon = line.firstIndex(of: ":") {
                    let word = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                    let aliases = String(line[line.index(after: colon)...])
                        .split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    return CustomVocabularyTerm(text: word, aliases: aliases.isEmpty ? nil : aliases)
                }
                return CustomVocabularyTerm(text: line)
            }
    }

    /// Fix trailing commas in CTC config.json that cause JSON parsing failures.
    private func fixCtcConfigJson() {
        let configURL = CtcModels.defaultCacheDirectory(for: .ctc110m)
            .appendingPathComponent("config.json")
        guard var content = try? String(contentsOf: configURL, encoding: .utf8) else { return }
        let original = content
        // Remove trailing commas before closing braces/brackets
        content = content.replacingOccurrences(
            of: #",\s*([}\]])"#,
            with: "$1",
            options: .regularExpression
        )
        if content != original {
            try? content.write(to: configURL, atomically: true, encoding: .utf8)
            log.info("Vocabulary: fixed trailing comma in CTC config.json")
        }
    }

    // MARK: - Paths

    private var appSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Dictascade", isDirectory: true)
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
    case noModelLoaded
    case noModelLoading

    var errorDescription: String? {
        switch self {
        case .notDownloaded(let engine):
            "\(engine.displayName) is not downloaded. Please download it from Settings."
        case .modelFilesNotFound(let engine):
            "\(engine.displayName) model files not found on disk."
        case .noModelLoaded:
            "No transcription model is loaded."
        case .noModelLoading:
            "No model is being loaded."
        }
    }
}
