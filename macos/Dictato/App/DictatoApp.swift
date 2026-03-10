import SwiftUI
import KeyboardShortcuts
import UniformTypeIdentifiers

extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}

@main
struct DictatoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var appState = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("Dictato", image: menuBarIcon) {
            if !appState.isEngineAvailable {
                Text("No model downloaded for current mode")
                    .foregroundStyle(.secondary)
                Divider()
            }

            Button(appState.isRecording ? "Stop Recording" : "Start Recording") {
                appState.toggleRecording()
            }
            .keyboardShortcut("r")
            .disabled(!appState.isEngineAvailable || appState.isTranscribing)

            Menu("Transcribe File...") {
                ForEach(appState.modes) { mode in
                    Button(mode.name) {
                        transcribeFileWithPicker(mode: mode)
                    }
                    .disabled(!appState.modelManager.isDownloaded(mode.transcriptionEngine))
                }
            }
            .disabled(appState.isRecording || appState.isTranscribing || appState.isFileTranscribing)

            Divider()

            Button("History") {
                appState.mainWindowTab = .history
                openMainWindow()
            }

            Button("Settings...") {
                appState.mainWindowTab = .settings
                openMainWindow()
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        Window("Dictato", id: "main") {
            MainWindowView()
                .toolbar(removing: .title)
                .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                    openMainWindow()
                }
        }
        .defaultSize(width: 620, height: 550)
    }

    private func transcribeFileWithPicker(mode: TranscriptionMode) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio, .aiff, .audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        appState.transcribeFile(url: url, mode: mode) { [openWindow] in
            AppState.shared.mainWindowTab = .history
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
    }

    private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    private var menuBarIcon: String {
        if !appState.isEngineAvailable {
            return "MenuBarIconOutline"
        }
        return "MenuBarIcon"
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var stateObservation: Task<Void, Never>?
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
        if runningInstances.count > 1 {
            NSApp.terminate(nil)
            return
        }

        let appState = AppState.shared

        // Watch for main window closing to switch back to accessory mode
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "Dictato",
                  !window.className.contains("StatusBar") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.setActivationPolicy(.accessory)
            }
        }

        Task { @MainActor in
            await appState.requestPermissions()

            // Auto-open Settings if no models are downloaded
            if !appState.modelManager.hasAnyModelDownloaded {
                appState.mainWindowTab = .settings
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .openMainWindow, object: nil)
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleRecording) {
            Task { @MainActor in
                guard !appState.isPaused else { return }
                appState.toggleRecording()
            }
        }

        stateObservation = Task { @MainActor [weak self] in
            var previousRecording = false
            var previousPaused = false
            var previousTranscribing = false
            var previousPostProcessing = false
            var previousError = false
            var previousModeIndex = 0
            var previousModelLoading = false

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }

                let recording = appState.isRecording
                let paused = appState.isPaused
                let transcribing = appState.isTranscribing
                let postProcessing = appState.isPostProcessing
                let error = appState.isError
                let modeIndex = appState.selectedModeIndex
                let modelLoading = appState.isModelLoading

                if recording != previousRecording || paused != previousPaused || transcribing != previousTranscribing || postProcessing != previousPostProcessing || error != previousError || modeIndex != previousModeIndex || modelLoading != previousModelLoading {
                    if recording || paused || transcribing || postProcessing || error || modelLoading {
                        showPanel(recording: recording, isPaused: paused, transcribing: transcribing, postProcessing: postProcessing, isError: error, isModelLoading: modelLoading)
                    } else {
                        hidePanel()
                    }
                    previousRecording = recording
                    previousPaused = paused
                    previousTranscribing = transcribing
                    previousPostProcessing = postProcessing
                    previousError = error
                    previousModeIndex = modeIndex
                    previousModelLoading = modelLoading
                }
            }
        }
    }

    @MainActor
    private func showPanel(recording: Bool, isPaused: Bool, transcribing: Bool, postProcessing: Bool = false, isError: Bool = false, isModelLoading: Bool = false) {
        let appState = AppState.shared
        let overlay = RecordingOverlay(
            isRecording: recording,
            isPaused: isPaused,
            isTranscribing: transcribing,
            isPostProcessing: postProcessing,
            isError: isError,
            modes: appState.modes,
            selectedModeIndex: appState.selectedModeIndex
        )
        // Measure pill-only size (overlay with single mode hides mode pills)
        let pillOnly = RecordingOverlay(
            isRecording: recording,
            isPaused: isPaused,
            isTranscribing: transcribing,
            isPostProcessing: postProcessing,
            isError: isError,
            modes: [appState.modes.first ?? .default],
            selectedModeIndex: 0
        )
        let pillMeasure = NSHostingView(rootView: pillOnly)
        let measuredPillSize = pillMeasure.fittingSize

        if panel == nil {
            panel = FloatingPanel(contentView: overlay)
            panel?.installKeyMonitor()
            panel?.installMouseMonitor()
        } else if let panel {
            let oldMidX = panel.frame.midX
            let hostingView = NSHostingView(rootView: overlay)
            panel.contentView = hostingView
            let size = hostingView.fittingSize
            panel.setContentSize(size)
            let newX = oldMidX - size.width / 2
            panel.setFrameOrigin(NSPoint(x: newX, y: panel.frame.origin.y))
        }
        panel?.pillSize = measuredPillSize
        panel?.orderFront(nil)
    }

    @MainActor
    private func hidePanel() {
        panel?.savePosition()
        panel?.removeKeyMonitor()
        panel?.removeMouseMonitor()
        panel?.orderOut(nil)
        panel = nil
    }

}
