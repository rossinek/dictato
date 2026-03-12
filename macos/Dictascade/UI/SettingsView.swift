import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var modelManager = AppState.shared.modelManager
    @AppStorage("openai_api_key") private var openAIKey = ""
    @AppStorage("groq_api_key") private var groqKey = ""

    fileprivate static let languages: [(String?, String)] = [
        (nil, "Auto-detect"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("ru", "Russian"),
        ("hi", "Hindi"),
        ("pl", "Polish"),
        ("sv", "Swedish"),
        ("uk", "Ukrainian"),
        ("tr", "Turkish"),
    ]

    var body: some View {
        Form {
            // Transcription Models
            Section("Transcription Models") {
                ForEach(TranscriptionEngine.allCases) { engine in
                    ModelRow(engine: engine, modelManager: modelManager)
                }
            }

            // Keyboard Shortcut
            Section("Keyboard Shortcut") {
                KeyboardShortcuts.Recorder("Toggle Recording:", name: .toggleRecording)
            }

            // API Keys
            Section("API Keys") {
                SecureField("OpenAI", text: $openAIKey)
                SecureField("Groq", text: $groqKey)
            }

            // Modes
            Section("Modes") {
                ForEach(appState.modes) { mode in
                    let modeID = mode.id
                    ModeRow(
                        mode: Binding(
                            get: { appState.modes.first(where: { $0.id == modeID }) ?? mode },
                            set: {
                                if let idx = appState.modes.firstIndex(where: { $0.id == modeID }) {
                                    appState.modes[idx] = $0
                                    appState.saveModes()
                                }
                            }
                        ),
                        modelManager: modelManager,
                        canDelete: appState.modes.count > 1,
                        onDelete: {
                            if let idx = appState.modes.firstIndex(where: { $0.id == modeID }) {
                                withAnimation(.spring(duration: 0.3)) {
                                    appState.modes.remove(at: idx)
                                    if appState.selectedModeIndex >= appState.modes.count {
                                        appState.selectedModeIndex = 0
                                    }
                                    appState.saveModes()
                                }
                            }
                        }
                    )
                }

                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        let mode = TranscriptionMode(
                            id: UUID(),
                            name: "Mode \(appState.modes.count + 1)",
                            language: nil,
                            prompt: ""
                        )
                        appState.modes.append(mode)
                        appState.saveModes()
                    }
                } label: {
                    Label("Add Mode", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Model Row

private struct ModelRow: View {
    let engine: TranscriptionEngine
    @ObservedObject var modelManager: ModelManager
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.displayName)
                    .font(.body.bold())
                Text(engine.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusView
        }
    }

    @ViewBuilder
    private var statusView: some View {
        let status = modelManager.status(for: engine)

        switch status {
        case .notDownloaded:
            Button("Download") {
                Task {
                    await modelManager.download(engine)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

        case .downloading(let progress):
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 80)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Downloading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .compiling:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Compiling model…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .downloaded:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                      .font(.system(size: 12))
                      .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .confirmationDialog("Delete \(engine.displayName)?", isPresented: $showDeleteConfirmation) {
                    Button("Delete", role: .destructive) {
                        modelManager.delete(engine)
                    }
                } message: {
                    Text("This will remove the downloaded model files. You can re-download later.")
                }
            }

        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)

                Button("Retry") {
                    Task {
                        await modelManager.download(engine)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Mode Row

private struct ModeRow: View {
    @Binding var mode: TranscriptionMode
    @ObservedObject var modelManager: ModelManager
    let canDelete: Bool
    let onDelete: () -> Void

    @State private var isExpanded = false
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    @State private var lastFetchedProvider: LLMProvider?

    private var downloadedEngines: [TranscriptionEngine] {
        TranscriptionEngine.allCases.filter { modelManager.isDownloaded($0) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 0) {
                settingsRow("Name") {
                    TextField("", text: $mode.name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }

                Divider()

                settingsRow("Language") {
                    Picker("", selection: languageBinding) {
                        ForEach(SettingsView.languages, id: \.0) { code, name in
                            Text(name).tag(code as String?)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Divider()

                if downloadedEngines.isEmpty {
                    settingsRow("Model") {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("None downloaded")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    settingsRow("Model") {
                        Picker("", selection: $mode.transcriptionEngine) {
                            ForEach(downloadedEngines) { engine in
                                Text(engine.displayName).tag(engine)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                Divider()

                settingsRow("Post-processing") {
                    Picker("", selection: $mode.provider) {
                        ForEach(LLMProvider.allCases, id: \.self) { provider in
                            if provider == .appleIntelligence && !LLMProvider.isAppleIntelligenceAvailable {
                                Text("\(provider.displayName) (not available)").tag(provider)
                                    .disabled(true)
                            } else {
                                Text(provider.displayName).tag(provider)
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                if mode.provider != .none {
                    if mode.provider.requiresModel {
                        Divider()

                        settingsRow("LLM") {
                            Picker("", selection: modelBinding) {
                                if isLoadingModels {
                                    Text("Loading…").tag(nil as String?)
                                } else if let error = modelLoadError {
                                    Text(error).tag(nil as String?)
                                } else {
                                    Text("Select model").tag(nil as String?)
                                    ForEach(availableModels, id: \.self) { model in
                                        Text(model).tag(model as String?)
                                    }
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .disabled(isLoadingModels || modelLoadError != nil)
                            .onChange(of: mode.provider) {
                                availableModels = []
                                modelLoadError = nil
                                mode.model = nil
                                fetchModels()
                            }
                            .onAppear {
                                if lastFetchedProvider != mode.provider {
                                    fetchModels()
                                }
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("System prompt")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $mode.prompt)
                            .font(.callout)
                            .frame(minHeight: 50, maxHeight: 100)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .topLeading) {
                                if mode.prompt.isEmpty {
                                    Text("Instructions for post-processing…")
                                        .foregroundStyle(.tertiary)
                                        .font(.callout)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } label: {
            HStack {
                Text(mode.name)
                    .font(.body.weight(.medium))

                if canDelete {
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation {
                    isExpanded.toggle()
                }
            }
        }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            content()
        }
        .padding(.vertical, 6)
    }

    private var languageBinding: Binding<String?> {
        Binding(
            get: { mode.language },
            set: { mode.language = $0 }
        )
    }

    private var modelBinding: Binding<String?> {
        Binding(
            get: { mode.model },
            set: { mode.model = $0 }
        )
    }

    private func fetchModels() {
        guard mode.provider != .none else { return }
        isLoadingModels = true
        modelLoadError = nil
        lastFetchedProvider = mode.provider
        Task {
            do {
                let models = try await LLMService.fetchModels(provider: mode.provider)
                availableModels = models
                if let current = mode.model, !models.contains(current) {
                    mode.model = nil
                }
            } catch {
                modelLoadError = error.localizedDescription
            }
            isLoadingModels = false
        }
    }
}

