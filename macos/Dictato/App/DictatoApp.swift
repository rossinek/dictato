import SwiftUI
import KeyboardShortcuts
import UniformTypeIdentifiers

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
                let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "history")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let window = NSApp.windows.first(where: { $0.title == "History" }) {
                        if let screen = mouseScreen {
                            let x = screen.visibleFrame.midX - window.frame.width / 2
                            let y = screen.visibleFrame.midY - window.frame.height / 2
                            window.setFrameOrigin(NSPoint(x: x, y: y))
                        }
                        window.orderFrontRegardless()
                    }
                }
            }

            SettingsLink {
                Text("Settings...")
            }
            .onAppear {}  // Force SwiftUI to register the settings scene
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    for window in NSApp.windows where window.title == "Settings" || window.className.contains("Settings") {
                        window.orderFrontRegardless()
                    }
                }
            })

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

    private func transcribeFileWithPicker(mode: TranscriptionMode) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio, .aiff, .audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        appState.transcribeFile(url: url, mode: mode) { [openWindow] in
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "history")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let window = NSApp.windows.first(where: { $0.title == "History" }) {
                    window.orderFrontRegardless()
                }
            }
        }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
        if runningInstances.count > 1 {
            NSApp.terminate(nil)
            return
        }

        let appState = AppState.shared

        Task { @MainActor in
            await appState.requestPermissions()

            // Auto-open Settings if no models are downloaded
            if !appState.modelManager.hasAnyModelDownloaded {
                NSApp.activate(ignoringOtherApps: true)
                // Open settings via NSApp standard mechanism
                if #available(macOS 14.0, *) {
                    NSApp.activate()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        for window in NSApp.windows where window.title == "Settings" || window.className.contains("Settings") {
                            window.orderFrontRegardless()
                        }
                    }
                }
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
