import SwiftUI
import UniformTypeIdentifiers

@main
struct DictatoApp: App {
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .task {
                    await appState.requestPermissions()
                    await appState.initializeASR()
                }
                .onOpenURL { url in
                    guard url.scheme == "dictato", url.host == "record" else { return }
                    let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "mode" })?.value
                    appState.pendingDeepLink = .record(mode: mode)
                }
        }
    }
}

struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab = 0
    @State private var showFileImporter = false
    @State private var showModePickerForFile: URL?

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "mic.fill", value: 0) {
                NavigationStack {
                    HomeView(appState: appState)
                }
            }

            Tab("History", systemImage: "clock", value: 1) {
                NavigationStack {
                    HistoryView(appState: appState)
                }
            }

            Tab("Settings", systemImage: "gear", value: 2) {
                NavigationStack {
                    SettingsView()
                }
            }

            Tab(value: 3, role: .search) {
                // never shown — intercepted below
                Color.clear
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue == 3 {
                showFileImporter = true
                selectedTab = 0
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .wav, .mp3, .aiff, UTType("public.aifc-audio") ?? .audio, UTType("com.apple.m4a-audio") ?? .audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                showModePickerForFile = url
            }
        }
        .confirmationDialog("Transcribe with mode", isPresented: Binding(
            get: { showModePickerForFile != nil },
            set: { if !$0 { showModePickerForFile = nil } }
        )) {
            ForEach(appState.modes) { mode in
                Button(mode.name) {
                    if let url = showModePickerForFile {
                        let secureAccess = url.startAccessingSecurityScopedResource()
                        appState.transcribeFile(url: url, mode: mode) {
                            if secureAccess { url.stopAccessingSecurityScopedResource() }
                            selectedTab = 1
                        }
                        showModePickerForFile = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                showModePickerForFile = nil
            }
        }
    }

}
