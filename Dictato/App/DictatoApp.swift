import SwiftUI
import KeyboardShortcuts

@main
struct DictatoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var appState = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("Dictato", systemImage: menuBarIcon) {
            if !appState.isModelLoaded {
                Text(appState.modelLoadingProgress)
                Divider()
            }

            Button(appState.isRecording ? "Stop Recording" : "Start Recording") {
                appState.toggleRecording()
            }
            .keyboardShortcut("r")
            .disabled(!appState.isModelLoaded || appState.isTranscribing)

            Divider()

            Button("History") {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            }

            SettingsLink {
                Text("Settings...")
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        Window("History", id: "history") {
            HistoryView(appState: appState)
                .toolbar(removing: .title)
        }
        .defaultSize(width: 620, height: 450)

        Settings {
            SettingsView()
                .toolbar(removing: .title)
        }
    }

    private var menuBarIcon: String {
        if !appState.isModelLoaded {
            return "arrow.down.circle.dotted"
        }
        if appState.isRecording {
            return "mic.fill"
        }
        return "mic"
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var stateObservation: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appState = AppState.shared

        Task { @MainActor in
            await appState.requestPermissions()
            await appState.initializeWhisperKit()
        }

        KeyboardShortcuts.onKeyDown(for: .toggleRecording) {
            Task { @MainActor in
                appState.toggleRecording()
            }
        }

        stateObservation = Task { @MainActor [weak self] in
            var previousRecording = false
            var previousPaused = false
            var previousTranscribing = false
            var previousPostProcessing = false
            var previousModeIndex = 0

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }

                let recording = appState.isRecording
                let paused = appState.isPaused
                let transcribing = appState.isTranscribing
                let postProcessing = appState.isPostProcessing
                let modeIndex = appState.selectedModeIndex

                if recording != previousRecording || paused != previousPaused || transcribing != previousTranscribing || postProcessing != previousPostProcessing || modeIndex != previousModeIndex {
                    if recording || paused || transcribing || postProcessing {
                        showPanel(recording: recording, isPaused: paused, transcribing: transcribing, postProcessing: postProcessing)
                    } else {
                        hidePanel()
                    }
                    previousRecording = recording
                    previousPaused = paused
                    previousTranscribing = transcribing
                    previousPostProcessing = postProcessing
                    previousModeIndex = modeIndex
                }
            }
        }
    }

    @MainActor
    private func showPanel(recording: Bool, isPaused: Bool, transcribing: Bool, postProcessing: Bool = false) {
        let appState = AppState.shared
        let overlay = RecordingOverlay(
            isRecording: recording,
            isPaused: isPaused,
            isTranscribing: transcribing,
            isPostProcessing: postProcessing,
            modes: appState.modes,
            selectedModeIndex: appState.selectedModeIndex
        )
        if panel == nil {
            panel = FloatingPanel(contentView: overlay)
            panel?.installKeyMonitor()
        } else {
            let hostingView = NSHostingView(rootView: overlay)
            panel?.contentView = hostingView
            let size = hostingView.fittingSize
            panel?.setContentSize(NSSize(width: max(360, size.width), height: size.height))
        }
        panel?.orderFront(nil)
    }

    @MainActor
    private func hidePanel() {
        panel?.removeKeyMonitor()
        panel?.orderOut(nil)
        panel = nil
    }

}
