import CoreML
import Foundation
import FluidAudio
import os
import WhisperKit

private let log = Logger(subsystem: "com.dictascade.app", category: "ModelManager")

/// OpenAI's Whisper Large V3 Turbo (4 decoder layers), fp16 Core ML build.
/// Do not use `openai_whisper-large-v3_turbo`: despite the name it is full Large V3
/// with 32 decoder layers (~6x slower). The quantized `_632MB` build decodes faster
/// but its first Core ML compilation takes ~2.5 min instead of ~15 s, and that
/// compilation repeats whenever the ANE cache is lost (new app path, eviction).
private let whisperVariant = "openai_whisper-large-v3-v20240930_turbo"
private let retiredWhisperVariant = "openai_whisper-large-v3_turbo"

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

/// Which compute units run Whisper (Settings → Whisper Acceleration).
enum WhisperAcceleration: String, CaseIterable, Identifiable {
    case hybrid
    case neuralEngine
    case gpu

    static let defaultsKey = "whisperAcceleration"

    static var current: WhisperAcceleration {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .hybrid
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hybrid: "Hybrid"
        case .neuralEngine: "Neural Engine only"
        case .gpu: "GPU only"
        }
    }

    var summary: String {
        switch self {
        case .hybrid:
            "Starts on the Neural Engine, then switches to the GPU once it has warmed up in the background."
        case .neuralEngine:
            "Runs entirely on the Neural Engine."
        case .gpu:
            "Runs entirely on the GPU."
        }
    }

    var pros: [String] {
        switch self {
        case .hybrid:
            ["Never waits for the GPU warm-up: ~1.6 s for the first recording",
             "~1 s for following recordings in a dictation session"]
        case .neuralEngine:
            ["Lowest power use — best on battery",
             "Leaves the GPU free for other apps (games, video)",
             "Lowest memory use"]
        case .gpu:
            ["~1 s per recording once warmed up",
             "No second encoder copy in memory during warm-up"]
        }
    }

    var cons: [String] {
        switch self {
        case .hybrid:
            ["Two encoder copies in memory for ~6 s while the GPU warms up",
             "Higher power use than the Neural Engine"]
        case .neuralEngine:
            ["Slowest: ~1.5 s per recording, also in dictation sessions"]
        case .gpu:
            ["Each load needs a ~5 s warm-up: a recording shorter than ~6 s waits up to ~5 s for it",
             "Higher power use than the Neural Engine"]
        }
    }

    fileprivate var computeOptions: ModelComputeOptions {
        switch self {
        case .hybrid, .neuralEngine:
            ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
        case .gpu:
            ModelComputeOptions(audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU)
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
        let replacesRetiredWhisper = removeRetiredModelFiles()
        checkExistingDownloads()
        // The user had downloaded Whisper explicitly; replace it with the current variant.
        if replacesRetiredWhisper, !isDownloaded(.whisperKit) {
            log.info("Replacing retired Whisper model with \(whisperVariant)")
            Task { await download(.whisperKit) }
        }
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
                variant: whisperVariant,
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
                    computeOptions: WhisperAcceleration.current.computeOptions,
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
        if engine == .whisperKit {
            releaseWhisper()
        } else if loadedEngine == engine {
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

    /// Reuses the instance held after the previous transcription, or joins a load
    /// already in flight. The load itself is not cancelled with the caller: it is
    /// short (~0.6 s from the Core ML cache) and the result is held for reuse.
    private func loadWhisperKit() async throws {
        cancelWhisperRelease()
        if whisperKit != nil, loadedWhisperAcceleration != WhisperAcceleration.current {
            releaseWhisper()
        }
        if whisperKit != nil { return }
        let task = whisperLoadTask ?? makeWhisperLoadTask(acceleration: .current)
        whisperLoadTask = task
        _ = try await task.value
    }

    private func makeWhisperLoadTask(acceleration: WhisperAcceleration) -> Task<Void, Error> {
        whisperLoadGeneration += 1
        let generation = whisperLoadGeneration
        return Task {
            defer { if whisperLoadGeneration == generation { whisperLoadTask = nil } }
            let downloadBase = whisperKitDownloadBase
            guard let modelFolder = whisperModelFolder ?? findWhisperModelFolder() else {
                throw ModelError.modelFilesNotFound(.whisperKit)
            }
            let start = CFAbsoluteTimeGetCurrent()
            let kit = try await WhisperKit(
                WhisperKitConfig(
                    downloadBase: downloadBase,
                    modelFolder: modelFolder.path,
                    tokenizerFolder: downloadBase,
                    computeOptions: acceleration.computeOptions,
                    verbose: true,
                    logLevel: .info,
                    prewarm: false,
                    download: false
                )
            )
            // Released (hold expired, model deleted, setting changed) while loading.
            try Task.checkCancellation()
            let loaded = CFAbsoluteTimeGetCurrent() - start
            // GPU only: the first encode after every load takes ~5 s; do it here so the
            // transcription waits for it instead of paying it inside the encoder timing.
            if acceleration == .gpu, let encoder = kit.audioEncoder as? AudioEncoder {
                try await Self.warmUp(encoder)
                try Task.checkCancellation()
            }
            whisperKit = kit
            loadedWhisperAcceleration = acceleration
            isWhisperEncoderOnGPU = acceleration == .gpu
            log.notice("""
                Whisper: loaded (\(acceleration.rawValue, privacy: .public)) in \
                \(String(format: "%.2f", loaded), privacy: .public) s, \
                ready after \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start), privacy: .public) s
                """)
            if acceleration == .hybrid {
                warmGPUEncoder(modelFolder: modelFolder)
            }
        }
    }

    /// Loads Whisper shortly after launch and transcribes 2 s of noise, so the first
    /// dictation does not pay one-time costs: after a new build/install the first ANE
    /// encode takes ~4 s, the first GPU load ~2 s and the first GPU decode ~1.5 s. The model is then held like after a transcription.
    func warmUpWhisperAtLaunch() {
        guard isDownloaded(.whisperKit) else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard whisperKit == nil, whisperLoadTask == nil else { return }
            let start = CFAbsoluteTimeGetCurrent()
            do {
                try await loadWhisperKit()
                if let kit = whisperKit {
                    // Low-level noise: WhisperKit skips audio under 1 s and silence,
                    // and this runs both the encoder and the decoder once.
                    let noise = (0..<32_000).map { _ in Float.random(in: -0.01...0.01) }
                    _ = try await kit.transcribe(
                        audioArray: noise,
                        decodeOptions: DecodingOptions(
                            language: "en", temperatureFallbackCount: 0, sampleLength: 4,
                            detectLanguage: false, wordTimestamps: false, chunkingStrategy: ChunkingStrategy.none
                        )
                    )
                }
                log.notice("Whisper: launch warm-up done in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start), privacy: .public) s")
            } catch {
                log.error("Whisper: launch warm-up failed: \(error)")
            }
            // A recording that started meanwhile owns the model and schedules the hold itself.
            if loadedEngine != .whisperKit, preloadingEngine != .whisperKit {
                scheduleWhisperRelease()
            }
        }
    }

    /// Applies a new acceleration setting: an idle held model is released now, one in
    /// use is released instead of held after its transcription.
    func setWhisperAcceleration(_ acceleration: WhisperAcceleration) {
        UserDefaults.standard.set(acceleration.rawValue, forKey: WhisperAcceleration.defaultsKey)
        guard whisperKit != nil, loadedWhisperAcceleration != acceleration, whisperReleaseTask != nil else { return }
        log.notice("Whisper: acceleration changed to \(acceleration.rawValue, privacy: .public)")
        releaseWhisper()
    }

    // MARK: - Whisper hold & GPU encoder

    /// How long Whisper stays in memory after a transcription, a cancelled recording
    /// or a switch to another mode, so the next dictation in a session starts warm.
    private static let whisperHoldDuration: Duration = .seconds(60)

    private var whisperLoadTask: Task<Void, Error>?
    private var whisperLoadGeneration = 0
    private var whisperReleaseTask: Task<Void, Never>?
    private var gpuEncoderTask: Task<Void, Never>?
    private var pendingGPUEncoder: AudioEncoder?
    private var isWhisperTranscribing = false
    private var isWhisperEncoderOnGPU = false
    private var loadedWhisperAcceleration: WhisperAcceleration = .hybrid
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Loads a second copy of the encoder on the GPU and swaps it in once its first
    /// encode (~5 s of MPS graph specialization, paid on every load) is done. Until
    /// then the ANE encoder serves transcriptions, so short recordings never wait.
    /// Warm GPU encode: ~0.7 s vs ~1.15 s on the ANE.
    private func warmGPUEncoder(modelFolder: URL) {
        gpuEncoderTask?.cancel()
        gpuEncoderTask = Task {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let encoder = AudioEncoder()
                try await encoder.loadModel(
                    at: modelFolder.appendingPathComponent("AudioEncoder.mlmodelc"),
                    computeUnits: .cpuAndGPU
                )
                try Task.checkCancellation()
                let loaded = CFAbsoluteTimeGetCurrent() - start
                try await Self.warmUp(encoder)
                try Task.checkCancellation()
                log.notice("""
                    Whisper: GPU encoder ready after \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start), privacy: .public) s \
                    (load \(String(format: "%.2f", loaded), privacy: .public) s)
                    """)
                pendingGPUEncoder = encoder
                installPendingGPUEncoder()
            } catch is CancellationError {
            } catch {
                log.error("Whisper: GPU encoder warm-up failed, staying on ANE: \(error)")
            }
            // A cancelled task may already have been replaced by a newer one.
            if !Task.isCancelled { gpuEncoderTask = nil }
        }
    }

    private nonisolated static func warmUp(_ encoder: AudioEncoder) async throws {
        guard let constraint = encoder.model?.modelDescription
            .inputDescriptionsByName["melspectrogram_features"]?.multiArrayConstraint else {
            throw ModelError.noModelLoaded
        }
        let features = try MLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
        features.withUnsafeMutableBytes { bytes, _ in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
        }
        _ = try await encoder.encodeFeatures(features)
    }

    /// Swaps encoders only between transcriptions; the ANE encoder is then released.
    private func installPendingGPUEncoder() {
        guard !isWhisperTranscribing, let encoder = pendingGPUEncoder, let kit = whisperKit else { return }
        kit.audioEncoder = encoder
        pendingGPUEncoder = nil
        isWhisperEncoderOnGPU = true
        log.notice("Whisper: switched encoder to GPU")
    }

    private func scheduleWhisperRelease() {
        guard whisperKit != nil || whisperLoadTask != nil else { return }
        if whisperKit != nil, loadedWhisperAcceleration != WhisperAcceleration.current {
            releaseWhisper()
            return
        }
        whisperReleaseTask?.cancel()
        startMemoryPressureMonitoring()
        log.notice("Whisper: holding in memory for \(String(describing: Self.whisperHoldDuration), privacy: .public)")
        whisperReleaseTask = Task {
            do { try await Task.sleep(for: Self.whisperHoldDuration) } catch { return }
            log.notice("Whisper: hold expired")
            releaseWhisper()
        }
    }

    private func cancelWhisperRelease() {
        whisperReleaseTask?.cancel()
        whisperReleaseTask = nil
    }

    private func releaseWhisper() {
        cancelWhisperRelease()
        whisperLoadTask?.cancel()
        whisperLoadTask = nil
        gpuEncoderTask?.cancel()
        gpuEncoderTask = nil
        pendingGPUEncoder = nil
        guard whisperKit != nil else { return }
        whisperKit = nil
        isWhisperEncoderOnGPU = false
        if loadedEngine == .whisperKit { loadedEngine = nil }
        log.notice("Whisper: released from memory")
    }

    /// Drops a held (idle) Whisper early when the system runs low on memory.
    private func startMemoryPressureMonitoring() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.whisperReleaseTask != nil else { return }
                log.notice("Whisper: releasing held model under memory pressure")
                self.releaseWhisper()
            }
        }
        source.resume()
        memoryPressureSource = source
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

        let audible = SilenceTrimmer.audibleRange(samples)
        guard !audible.isEmpty else {
            log.notice("Whisper: recording is digital silence, skipping transcription")
            return ""
        }
        installPendingGPUEncoder()
        let encoderUnit = isWhisperEncoderOnGPU ? "GPU" : "ANE"
        isWhisperTranscribing = true
        defer {
            isWhisperTranscribing = false
            installPendingGPUEncoder()
        }
        let start = CFAbsoluteTimeGetCurrent()
        let results = try await kit.transcribe(
            audioArray: Array(samples[audible]),
            decodeOptions: DecodingOptions(
                language: language,
                // At most one re-decode at a higher temperature: each fallback repeats
                // the whole decode and rarely improves dictation.
                temperatureFallbackCount: 1,
                // With language nil WhisperKit otherwise forces English.
                detectLanguage: language == nil,
                wordTimestamps: false,
                chunkingStrategy: .none
            )
        )

        let timings = results.first?.timings
        log.notice("""
            Whisper: \(String(format: "%.1f", Double(audible.count) / 16000), privacy: .public) s audio \
            (trimmed \(String(format: "%.1f", Double(samples.count - audible.count) / 16000), privacy: .public) s silence), \
            total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start), privacy: .public) s, \
            encoder \(String(format: "%.2f", timings?.encoding ?? 0), privacy: .public) s (\(encoderUnit, privacy: .public)), \
            decoder \(String(format: "%.2f", (timings?.decodingLoop ?? 0) - (timings?.encoding ?? 0)), privacy: .public) s, \
            fallbacks \(Int(timings?.totalDecodingFallbacks ?? 0)), \
            language \(results.first?.language ?? "?", privacy: .public)
            """)

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

    /// Whisper is not freed here: it is held for `whisperHoldDuration`, then released.
    private func unload(_ engine: TranscriptionEngine) {
        switch engine {
        case .whisperKit:
            if loadedEngine == engine { loadedEngine = nil }
            scheduleWhisperRelease()
            return
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

    /// Remove app-owned downloads of retired models, never shared caches.
    /// Returns true when a retired Whisper model was removed.
    @discardableResult
    private func removeRetiredModelFiles() -> Bool {
        let lfm3 = appSupportDirectory.appendingPathComponent("LFM3Audio", isDirectory: true)
        removeRetired(lfm3)
        return removeRetired(whisperModelFolder(for: retiredWhisperVariant))
    }

    @discardableResult
    private func removeRetired(_ directory: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        do {
            try FileManager.default.removeItem(at: directory)
            log.info("Removed retired model files at \(directory.lastPathComponent)")
            return true
        } catch {
            log.error("Could not remove retired model files at \(directory.path): \(error)")
            return false
        }
    }

    private func whisperModelFolder(for variant: String) -> URL {
        // WhisperKit downloads to: base/models/argmaxinc/whisperkit-coreml/<variant>
        whisperKitDownloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)")
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
        let expected = whisperModelFolder(for: whisperVariant)
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
