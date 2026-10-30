import Foundation
import FluidAudio
import os
import WhisperKit

private let log = Logger(subsystem: "com.dictascade.app", category: "ModelManager")

enum TranscriptionEngine: String, Codable, CaseIterable, Identifiable {
    case parakeetUltra
    case fluidAudio
    case whisperKit

    var id: String { rawValue }

    static func fromPersistedValue(_ value: String) -> TranscriptionEngine? {
        value == "lfm3Audio" ? .parakeetUltra : TranscriptionEngine(rawValue: value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let engine = Self.fromPersistedValue(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown transcription engine: \(value)")
        }
        self = engine
    }

    var displayName: String {
        switch self {
        case .whisperKit: "Whisper Large V3 Turbo"
        case .fluidAudio: "Parakeet TDT V3"
        case .parakeetUltra: "Parakeet Ultra"
        }
    }

    var description: String {
        switch self {
        case .whisperKit: "OpenAI — via WhisperKit"
        case .fluidAudio: "Nvidia — via FluidAudio"
        case .parakeetUltra: "Nvidia — via FluidAudio · ~630 MB"
        }
    }

    var keepLoaded: Bool {
        switch self {
        case .whisperKit: false
        case .fluidAudio, .parakeetUltra: true
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
    private var ctcSpotter: CtcKeywordSpotter?
    private var vocabularyRescorer: VocabularyRescorer?
    private var customVocabularyContext: CustomVocabularyContext?

    init() {
        removeRetiredModelFiles()
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
        switch status(for: engine) {
        case .downloading, .compiling, .loading, .downloaded: return
        default: break
        }

        switch engine {
        case .whisperKit:
            await downloadWhisperKit()
        case .fluidAudio, .parakeetUltra:
            await downloadFluidAudio(engine)
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

    private func downloadFluidAudio(_ engine: TranscriptionEngine) async {
        statuses[engine] = .downloading(progress: nil)
        do {
            let directory = parakeetDirectory(for: engine)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try await AsrModels.download(to: directory, version: parakeetVersion(for: engine))
            statuses[engine] = .downloaded
        } catch {
            statuses[engine] = .error(error.localizedDescription)
            log.error("Parakeet download failed: \(error)")
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
            case .fluidAudio, .parakeetUltra:
                let dir = parakeetDirectory(for: engine)
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

        if preloadingEngine == engine { return }
        guard isDownloaded(engine) else { return }

        // Serialize model loads: cancelled Core ML work may still be finishing.
        let previousTask = preloadTask
        cancelPreload()
        if let current = loadedEngine { unload(current) }
        preloadingEngine = engine
        statuses[engine] = .loading

        preloadTask = Task {
            _ = try? await previousTask?.value
            do {
                try Task.checkCancellation()
                try await loadEngine(engine)
                try Task.checkCancellation()
                loadedEngine = engine
                preloadingEngine = nil
                statuses[engine] = .downloaded
            } catch {
                unload(engine)
                if !Task.isCancelled {
                    preloadingEngine = nil
                    statuses[engine] = .error(error.localizedDescription)
                }
                throw error
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
        guard loadedEngine != nil else { throw ModelError.noModelLoaded }
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
        case .fluidAudio, .parakeetUltra:
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
            preloadingEngine = nil
            statuses[engine] = .downloaded
        }
    }

    // MARK: - Internal Load/Unload

    private func loadEngine(_ engine: TranscriptionEngine) async throws {
        switch engine {
        case .whisperKit:
            try await loadWhisperKit()
        case .fluidAudio, .parakeetUltra:
            try await loadFluidAudio(engine)

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
        try Task.checkCancellation()
        whisperKit = kit
    }

    private func loadFluidAudio(_ engine: TranscriptionEngine) async throws {
        let directory = parakeetDirectory(for: engine)
        let models = try await AsrModels.load(from: directory, version: parakeetVersion(for: engine))
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        try Task.checkCancellation()
        asrManager = manager

        // Apply vocabulary boosting if configured
        let vocab = UserDefaults.standard.string(forKey: "vocabulary") ?? ""
        if !vocab.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configureVocabulary(vocab)
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

        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Apply vocabulary rescoring if configured
        if let spotter = ctcSpotter,
           let rescorer = vocabularyRescorer,
           let vocab = customVocabularyContext,
           let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty {
            do {
                let spotResult = try await spotter.spotKeywordsWithLogProbs(
                    audioSamples: samples,
                    customVocabulary: vocab
                )
                if !spotResult.logProbs.isEmpty {
                    let rescoreOutput = rescorer.ctcTokenRescore(
                        transcript: text,
                        tokenTimings: tokenTimings,
                        logProbs: spotResult.logProbs,
                        frameDuration: spotResult.frameDuration,
                        minSimilarity: VocabularyPolicy.minSimilarity
                    )
                    if rescoreOutput.wasModified {
                        text = rescoreOutput.text
                        log.info("Vocabulary: applied \(rescoreOutput.replacements.count) replacement(s)")
                    }
                }
            } catch {
                log.error("Vocabulary rescoring failed: \(error)")
            }
        }

        return text
    }

    private func unload(_ engine: TranscriptionEngine) {
        switch engine {
        case .whisperKit:
            whisperKit = nil
        case .fluidAudio, .parakeetUltra:
            asrManager = nil
            ctcSpotter = nil
            vocabularyRescorer = nil
            customVocabularyContext = nil
        }
        if loadedEngine == engine {
            loadedEngine = nil
        }
        log.info("Unloaded: \(engine.displayName)")
    }

    // MARK: - Vocabulary Boosting

    func configureVocabulary(_ text: String) {
        let terms = parseVocabularyTerms(text)
        guard !terms.isEmpty else {
            ctcSpotter = nil
            vocabularyRescorer = nil
            customVocabularyContext = nil
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
                let blankId = ctcModels.vocabulary.count
                let spotter = CtcKeywordSpotter(models: ctcModels, blankId: blankId)
                let ctcModelDir = CtcModels.defaultCacheDirectory(for: ctcModels.variant)
                let rescorer = try await VocabularyRescorer.create(
                    spotter: spotter,
                    vocabulary: vocab,
                    config: VocabularyPolicy.rescoringConfig,
                    ctcModelDirectory: ctcModelDir
                )

                self.ctcSpotter = spotter
                self.vocabularyRescorer = rescorer
                self.customVocabularyContext = vocab
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

    private func parakeetDirectory(for engine: TranscriptionEngine) -> URL {
        // AsrModels resolves a repo-named sibling of the supplied directory.
        // Use that actual location for download, detection and deletion alike.
        let repo: Repo = engine == .parakeetUltra ? .parakeetUltra : .parakeetV3
        return appSupportDirectory.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    private func parakeetVersion(for engine: TranscriptionEngine) -> AsrModelVersion {
        engine == .parakeetUltra ? .ultra : .v3
    }

    /// LFM3 was retired; remove only its app-owned download, never shared caches.
    private func removeRetiredModelFiles() {
        let directory = appSupportDirectory.appendingPathComponent("LFM3Audio", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            log.error("Could not remove retired LFM3 download: \(error)")
        }
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

        for engine in [TranscriptionEngine.fluidAudio, .parakeetUltra] {
            statuses[engine] = AsrModels.modelsExist(
                at: parakeetDirectory(for: engine), version: parakeetVersion(for: engine)
            ) ? .downloaded : .notDownloaded
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
