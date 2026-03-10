import AppIntents
import SwiftUI

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description: IntentDescription = "Opens Dictato and starts recording with the selected mode."
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

struct DictatoShortcuts: AppShortcutsProvider {
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
    }
}
