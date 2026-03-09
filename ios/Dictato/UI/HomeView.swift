import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject var appState: AppState
    @State private var showFileImporter = false
    @State private var showModePickerForFile: URL?
    @State private var navigateToHistory = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            if !appState.isModelLoaded {
                modelLoadingView
            } else if appState.isError {
                errorView
            } else if appState.isPostProcessing {
                statusView(color: .blue, text: "Post-processing...", pulsing: false)
                ProgressView()
                cancelButton
            } else if appState.isTranscribing {
                statusView(color: .orange, text: "Transcribing...", pulsing: false)
                ProgressView()
                cancelButton
            } else if appState.isPaused {
                statusView(color: .yellow, text: "Paused", pulsing: false)
                pausedButtons
            } else if appState.isRecording {
                statusView(color: .red, text: "Recording...", pulsing: true)
                modePills
                recordingButtons
            } else {
                modePills
                recordButton
            }

            Spacer()

            if appState.isModelLoaded && !appState.isRecording && !appState.isPaused && !appState.isTranscribing && !appState.isPostProcessing && !appState.isError {
                bottomToolbar
            }
        }
        .padding(20)
        .navigationTitle("Dictato")
        .navigationDestination(isPresented: $navigateToHistory) {
            HistoryView(appState: appState)
        }
        .sheet(item: $appState.lastTranscriptionResult) { transcription in
            ResultSheet(transcription: transcription) {
                appState.lastTranscriptionResult = nil
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
                            navigateToHistory = true
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

    // MARK: - Subviews

    private var modelLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(appState.modelLoadingProgress)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func statusView(color: Color, text: String, pulsing: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .scaleEffect(pulsing ? 1.3 : 1.0)
                .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulsing)

            Text(text)
                .font(.system(size: 16, weight: .semibold))
        }
    }

    private var modePills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(appState.modes.enumerated()), id: \.element.id) { index, mode in
                    Text(mode.name)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            appState.selectedModeIndex == index ? Color.accentColor : Color.secondary.opacity(0.2),
                            in: Capsule()
                        )
                        .foregroundStyle(appState.selectedModeIndex == index ? .white : .primary)
                        .onTapGesture {
                            appState.selectMode(index: index)
                        }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var recordButton: some View {
        Button {
            appState.startRecording()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 32))
                .foregroundStyle(.white)
                .frame(width: 80, height: 80)
                .background(.red, in: Circle())
        }
    }

    private var recordingButtons: some View {
        HStack(spacing: 24) {
            Button {
                appState.togglePause()
            } label: {
                Label("Pause", systemImage: "pause.fill")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.bordered)

            Button {
                appState.stopAndTranscribe()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }

    private var pausedButtons: some View {
        HStack(spacing: 24) {
            Button {
                appState.togglePause()
            } label: {
                Label("Resume", systemImage: "play.fill")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                appState.discardRecording()
            } label: {
                Label("Discard", systemImage: "trash")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.bordered)
        }
    }

    private var cancelButton: some View {
        Button("Cancel") {
            appState.cancelTranscription()
        }
        .buttonStyle(.bordered)
    }

    private var errorView: some View {
        VStack(spacing: 16) {
            statusView(color: .red, text: "Transcription failed", pulsing: false)

            HStack(spacing: 16) {
                Button("Dismiss") {
                    appState.dismissError()
                }
                .buttonStyle(.bordered)

                Button("Save Recording") {
                    appState.saveFailedRecording()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .sheet(item: $appState.failedRecordingURL) { url in
            ShareSheet(activityItems: [url])
        }
    }

    private var bottomToolbar: some View {
        HStack(spacing: 24) {
            NavigationLink {
                HistoryView(appState: appState)
            } label: {
                Label("History", systemImage: "clock")
            }

            NavigationLink {
                SettingsView()
            } label: {
                Label("Settings", systemImage: "gear")
            }

            Button {
                showFileImporter = true
            } label: {
                Label("Import File", systemImage: "doc.badge.plus")
            }
            .disabled(appState.isFileTranscribing)
        }
        .font(.body)
    }
}

// MARK: - Result Sheet

private struct ResultSheet: View {
    let transcription: Transcription
    let onDismiss: () -> Void
    @State private var selectedTab: Int
    @State private var copied = false

    init(transcription: Transcription, onDismiss: @escaping () -> Void) {
        self.transcription = transcription
        self.onDismiss = onDismiss
        self._selectedTab = State(initialValue: transcription.postProcessedText != nil ? 1 : 0)
    }

    private var displayedText: String {
        if selectedTab == 1, let processed = transcription.postProcessedText {
            return processed
        }
        return transcription.text
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if transcription.postProcessedText != nil {
                    HStack(spacing: 0) {
                        tabButton("Original", tag: 0)
                        tabButton("Post-processed", tag: 1)
                    }
                    .background(Color.secondary.opacity(0.2), in: Capsule())
                }

                ScrollView {
                    Text(displayedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }

                if let modeName = transcription.modeName {
                    Text(modeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    UIPasteboard.general.string = displayedText
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }
            .padding()
            .navigationTitle("Transcription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }

    private func tabButton(_ label: String, tag: Int) -> some View {
        Text(label)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selectedTab == tag ? Color.accentColor : Color.clear, in: Capsule())
            .foregroundStyle(selectedTab == tag ? .white : .secondary)
            .onTapGesture { selectedTab = tag }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - URL Identifiable

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
