import SwiftUI
import KeyboardShortcuts
import UniformTypeIdentifiers

@main
struct DictascadeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var appState = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("Dictascade", image: menuBarIcon) {
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

        Window("Dictascade", id: "main") {
            MainWindowView()
                .toolbar(removing: .title)
        }
        .defaultSize(width: 620, height: 550)
        .defaultLaunchBehavior(.presented)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.windows.first { $0.title == "Dictascade" && !$0.className.contains("StatusBar") }?
                .orderFrontRegardless()
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
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
        if runningInstances.count > 1 {
            // Tell the first instance to open its main window
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.dictascade.openMainWindow"),
                object: nil
            )
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
                  window.title == "Dictascade",
                  !window.className.contains("StatusBar") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.setActivationPolicy(.accessory)
            }
        }

        // Listen for second instance asking us to open the window
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.dictascade.openMainWindow"),
            object: nil,
            queue: .main
        ) { _ in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }

        Task { @MainActor in
            await appState.requestPermissions()
        }

        appState.mainWindowTab = .settings

        KeyboardShortcuts.onKeyDown(for: .toggleRecording) {
            Task { @MainActor in
                guard !appState.isPaused else { return }
                appState.toggleRecording()
            }
        }

        KeyboardShortcuts.onKeyDown(for: .pasteLastTranscription) {
            Task { @MainActor in
                guard let last = appState.transcriptionHistory.first else { return }
                let text = last.postProcessedText ?? last.text
                PasteService.paste(text: text)
            }
        }

        stateObservation = Task { @MainActor [weak self] in
            var wasVisible = false

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }

                let shouldShow = appState.isRecording || appState.isPaused ||
                    appState.isTranscribing || appState.isPostProcessing ||
                    appState.isError || appState.isModelLoading

                if shouldShow && !wasVisible {
                    showPanel()
                    wasVisible = true
                } else if !shouldShow && wasVisible {
                    hidePanel()
                    wasVisible = false
                } else if shouldShow {
                    resizePanel()
                }
            }
        }
    }

    @MainActor
    private func showPanel() {
        if panel == nil {
            panel = FloatingPanel(contentView: RecordingOverlay())
            panel?.installKeyMonitor()
        }
        panel?.orderFront(nil)
    }

    @MainActor
    private func resizePanel() {
        guard let panel, let contentView = panel.contentView else { return }
        let size = contentView.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let currentSize = panel.frame.size
        if abs(size.width - currentSize.width) > 1 || abs(size.height - currentSize.height) > 1 {
            let oldMidX = panel.frame.midX
            panel.setContentSize(size)
            let newX = oldMidX - size.width / 2
            panel.setFrameOrigin(NSPoint(x: newX, y: panel.frame.origin.y))
        }
    }

    @MainActor
    private func hidePanel() {
        panel?.savePosition()
        panel?.removeKeyMonitor()

        panel?.orderOut(nil)
        panel = nil
    }

}
