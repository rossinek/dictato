import AppIntents
import SwiftUI

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description: IntentDescription = "Opens Dictascade and starts recording with the selected mode."
    static var openAppWhenRun = true

    @Parameter(title: "Mode")
    var mode: ModeEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        let appState = AppState.shared
        if let mode {
            if let index = appState.modes.firstIndex(where: { $0.id.uuidString == mode.id }) {
                appState.selectMode(index: index)
            }
        }
        appState.pendingDeepLink = .record(mode: nil)
        return .result()
    }
}

// MARK: - Transcribe File Intent

struct TranscribeFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Transcribe Audio File"
    static var description: IntentDescription = "Transcribes an audio file and returns the text. The model must be loaded first by opening Dictascade."
    static var openAppWhenRun = false

    @Parameter(title: "Audio File", supportedContentTypes: [.audio])
    var file: IntentFile

    @Parameter(title: "Mode")
    var mode: ModeEntity?

    @MainActor
    func perform() async throws -> some ReturnsValue<String> {
        let appState = AppState.shared

        // In background mode we can't afford the time to download/compile the model.
        // The user must have opened the app at least once so the model is cached.
        if !appState.isModelLoaded {
            await appState.initializeASR()
        }
        guard appState.isModelLoaded else {
            throw AppState.TranscriptionError.modelNotLoaded
        }

        // Resolve the transcription mode
        let transcriptionMode: TranscriptionMode
        if let mode,
           let match = appState.modes.first(where: { $0.id.uuidString == mode.id }) {
            transcriptionMode = match
        } else {
            transcriptionMode = appState.selectedMode
        }

        // Write file data to a temp URL so AVAudioFile can read it
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(file.filename ?? "audio.wav")
        try file.data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let text = try await appState.transcribeFileAsync(url: tempURL, mode: transcriptionMode)
        return .result(value: text)
    }
}

// MARK: - Mode Entity

struct ModeEntity: AppEntity {
    var id: String
    var name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mode"
    static var defaultQuery = ModeEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ModeEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ModeEntity] {
        AppState.shared.modes
            .filter { identifiers.contains($0.id.uuidString) }
            .map { ModeEntity(id: $0.id.uuidString, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ModeEntity] {
        AppState.shared.modes.map { ModeEntity(id: $0.id.uuidString, name: $0.name) }
    }
}

// MARK: - Shortcuts Provider

struct DictascadeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording with \(.applicationName)",
                "Record with \(.applicationName)",
                "Transcribe with \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: TranscribeFileIntent(),
            phrases: [
                "Transcribe a file with \(.applicationName)",
                "Transcribe audio with \(.applicationName)"
            ],
            shortTitle: "Transcribe File",
            systemImageName: "doc.text"
        )
    }
}
