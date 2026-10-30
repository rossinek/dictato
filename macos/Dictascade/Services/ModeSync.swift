import Foundation
import os

// MARK: - Wire Format

struct SharedMode: Codable {
    let id: UUID
    var name: String
    var language: String?
    var prompt: String
    var provider: LLMProvider
    var model: String?
}

struct ModeSyncPayload: Codable {
    let version: Int
    let modes: [SharedMode]
    let updatedAt: Date
    let deviceID: String
}

// MARK: - Sync Conflict

struct SyncConflict {
    let localOnly: [TranscriptionMode]
    let remoteOnly: [SharedMode]
    let conflicts: [(local: TranscriptionMode, remote: SharedMode)]
    let matching: [UUID]

    var hasConflict: Bool {
        !localOnly.isEmpty || !remoteOnly.isEmpty || !conflicts.isEmpty
    }
}

// MARK: - ModeSync

@MainActor
final class ModeSync {
    static let shared = ModeSync()

    private let store = NSUbiquitousKeyValueStore.default
    private let storeKey = "modes"
    private let vocabularyKey = "vocabulary"
    private let engineMapKey = "modeEngines"
    private let log = Logger(subsystem: "com.dictascade.app", category: "ModeSync")

    private var isObserving = false

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "iCloudModeSync") as? Bool ?? true
    }

    var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "modeSyncDeviceID") {
            return id
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "modeSyncDeviceID")
        return id
    }

    /// Callback when remote modes arrive. Delivers SharedModes directly — caller converts to TranscriptionMode.
    var onRemoteChange: (([SharedMode]) -> Void)?
    /// Callback when remote vocabulary arrives.
    var onVocabularyChange: ((String) -> Void)?

    func start() {
        guard isEnabled else { return }
        store.synchronize()
        startObserving()
        log.info("ModeSync started (device: \(self.deviceID.prefix(8))...)")
    }

    func stop() {
        stopObserving()
        log.info("ModeSync stopped")
    }

    func pushModes(_ modes: [TranscriptionMode]) {
        guard isEnabled else { return }

        let shared = modes.map { SharedMode(id: $0.id, name: $0.name, language: $0.language, prompt: $0.prompt, provider: $0.provider, model: $0.model) }
        let payload = ModeSyncPayload(version: 1, modes: shared, updatedAt: Date(), deviceID: deviceID)

        do {
            let data = try JSONEncoder().encode(payload)
            store.set(data, forKey: storeKey)
            log.info("Pushed \(modes.count) modes to iCloud")
        } catch {
            log.error("Failed to encode modes for iCloud: \(error)")
        }
    }

    /// Returns the current remote payload, or nil if none exists / decode fails.
    func fetchRemote() -> ModeSyncPayload? {
        guard isEnabled else { return nil }
        guard let data = store.data(forKey: storeKey) else { return nil }
        return try? JSONDecoder().decode(ModeSyncPayload.self, from: data)
    }

    // MARK: - Vocabulary Sync

    func pushVocabulary(_ text: String) {
        guard isEnabled else { return }
        store.set(text, forKey: vocabularyKey)
        log.info("Pushed vocabulary to iCloud")
    }

    func fetchRemoteVocabulary() -> String? {
        guard isEnabled else { return nil }
        return store.string(forKey: vocabularyKey)
    }

    // MARK: - Conflict Analysis

    func analyzeConflict(local: [TranscriptionMode], remote: [SharedMode]) -> SyncConflict {
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })

        var localOnly: [TranscriptionMode] = []
        var remoteOnly: [SharedMode] = []
        var conflicts: [(local: TranscriptionMode, remote: SharedMode)] = []
        var matching: [UUID] = []

        for mode in local {
            if let r = remoteByID[mode.id] {
                if mode.name == r.name && mode.prompt == r.prompt && mode.provider == r.provider && mode.model == r.model && mode.language == r.language {
                    matching.append(mode.id)
                } else {
                    conflicts.append((local: mode, remote: r))
                }
            } else {
                localOnly.append(mode)
            }
        }

        for shared in remote {
            if localByID[shared.id] == nil {
                remoteOnly.append(shared)
            }
        }

        return SyncConflict(localOnly: localOnly, remoteOnly: remoteOnly, conflicts: conflicts, matching: matching)
    }

    func mergeModes(local: [TranscriptionMode], remote: [SharedMode]) -> [TranscriptionMode] {
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let engineMap = UserDefaults.standard.dictionary(forKey: engineMapKey) as? [String: String] ?? [:]

        // Start with remote order
        var result: [TranscriptionMode] = remote.map { shared in
            let engine: TranscriptionEngine
            if let raw = engineMap[shared.id.uuidString], let mapped = TranscriptionEngine.fromPersistedValue(raw) {
                engine = mapped
            } else if let existing = localByID[shared.id] {
                engine = existing.transcriptionEngine
            } else {
                engine = .fluidAudio
            }
            return TranscriptionMode(
                id: shared.id,
                name: shared.name,
                language: shared.language,
                prompt: shared.prompt,
                provider: shared.provider,
                model: shared.model,
                transcriptionEngine: engine
            )
        }

        // Append local-only modes at end
        let remoteIDs = Set(remote.map { $0.id })
        for mode in local where !remoteIDs.contains(mode.id) {
            result.append(mode)
        }

        return result
    }

    // MARK: - Local Engine Map (macOS only)

    func saveEngineMap(_ modes: [TranscriptionMode]) {
        var map: [String: String] = [:]
        for mode in modes {
            map[mode.id.uuidString] = mode.transcriptionEngine.rawValue
        }
        UserDefaults.standard.set(map, forKey: engineMapKey)
    }

    func applyEngineMap(_ sharedModes: [SharedMode]) -> [TranscriptionMode] {
        let map = UserDefaults.standard.dictionary(forKey: engineMapKey) as? [String: String] ?? [:]
        return sharedModes.map { shared in
            let engine: TranscriptionEngine
            if let raw = map[shared.id.uuidString], let mapped = TranscriptionEngine.fromPersistedValue(raw) {
                engine = mapped
            } else {
                engine = .fluidAudio
            }
            return TranscriptionMode(
                id: shared.id,
                name: shared.name,
                language: shared.language,
                prompt: shared.prompt,
                provider: shared.provider,
                model: shared.model,
                transcriptionEngine: engine
            )
        }
    }

    // MARK: - Observation

    private func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRemoteChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
    }

    private func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        NotificationCenter.default.removeObserver(
            self,
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
    }

    @objc private nonisolated func handleRemoteChange(_ notification: Notification) {
        Task { @MainActor in
            guard isEnabled else { return }

            // Modes
            if let data = store.data(forKey: storeKey) {
                do {
                    let remote = try JSONDecoder().decode(ModeSyncPayload.self, from: data)
                    if remote.deviceID != deviceID {
                        log.info("Received remote mode change from device \(remote.deviceID.prefix(8))...")
                        onRemoteChange?(remote.modes)
                    }
                } catch {
                    log.error("Failed to decode remote change: \(error)")
                }
            }

            // Vocabulary
            if let remoteVocab = store.string(forKey: vocabularyKey) {
                let localVocab = UserDefaults.standard.string(forKey: "vocabulary") ?? ""
                if remoteVocab != localVocab {
                    log.info("Received remote vocabulary change")
                    onVocabularyChange?(remoteVocab)
                }
            }
        }
    }
}
