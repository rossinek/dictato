import SwiftUI
import KeyboardShortcuts

@main
struct DictatoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var appState = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("Dictato", image: menuBarIcon) {
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

    private var menuBarIcon: String {
        if !appState.isModelLoaded {
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
            await appState.initializeWhisperKit()
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

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }

                let recording = appState.isRecording
                let paused = appState.isPaused
                let transcribing = appState.isTranscribing
                let postProcessing = appState.isPostProcessing
                let error = appState.isError
                let modeIndex = appState.selectedModeIndex

                if recording != previousRecording || paused != previousPaused || transcribing != previousTranscribing || postProcessing != previousPostProcessing || error != previousError || modeIndex != previousModeIndex {
                    if recording || paused || transcribing || postProcessing || error {
                        showPanel(recording: recording, isPaused: paused, transcribing: transcribing, postProcessing: postProcessing, isError: error)
                    } else {
                        hidePanel()
                    }
                    previousRecording = recording
                    previousPaused = paused
                    previousTranscribing = transcribing
                    previousPostProcessing = postProcessing
                    previousError = error
                    previousModeIndex = modeIndex
                }
            }
        }
    }

    @MainActor
    private func showPanel(recording: Bool, isPaused: Bool, transcribing: Bool, postProcessing: Bool = false, isError: Bool = false) {
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
