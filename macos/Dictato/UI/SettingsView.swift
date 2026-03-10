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
        ScrollView {
            VStack(spacing: 20) {
                // Transcription Models
                SectionCard("Transcription Models") {
                    VStack(spacing: 12) {
                        ForEach(TranscriptionEngine.allCases) { engine in
                            ModelRow(engine: engine, modelManager: modelManager)

                            if engine != TranscriptionEngine.allCases.last {
                                Divider()
                            }
                        }
                    }
                }

                // Keyboard Shortcut
                SectionCard("Keyboard Shortcut") {
                    KeyboardShortcuts.Recorder("Toggle Recording:", name: .toggleRecording)
                }

                // API Keys
                SectionCard("API Keys") {
                    VStack(spacing: 12) {
                        SecureField("OpenAI API Key", text: $openAIKey)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Groq API Key", text: $groqKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                // Modes
                SectionCard("Modes") {
                    VStack(spacing: 16) {
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
                                        appState.modes.remove(at: idx)
                                        if appState.selectedModeIndex >= appState.modes.count {
                                            appState.selectedModeIndex = 0
                                        }
                                        appState.saveModes()
                                    }
                                }
                            )

                            if mode.id != appState.modes.last?.id {
                                Divider()
                            }
                        }

                        Button {
                            let mode = TranscriptionMode(
                                id: UUID(),
                                name: "Mode \(appState.modes.count + 1)",
                                language: nil,
                                prompt: ""
                            )
                            appState.modes.append(mode)
                            appState.saveModes()
                        } label: {
                            Label("Add Mode", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
        }
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
                Text("Compiling model (first time, may take a few minutes)...")
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

// MARK: - Section Card

private struct SectionCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Mode Row

private struct ModeRow: View {
    @Binding var mode: TranscriptionMode
    @ObservedObject var modelManager: ModelManager
    let canDelete: Bool
    let onDelete: () -> Void

    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    @State private var modelSearch = ""
    @FocusState private var isSearchFocused: Bool

    private var downloadedEngines: [TranscriptionEngine] {
        TranscriptionEngine.allCases.filter { modelManager.isDownloaded($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Name", text: $mode.name)
                    .textFieldStyle(.roundedBorder)

                Picker("Language", selection: languageBinding) {
                    ForEach(SettingsView.languages, id: \.0) { code, name in
                        Text(name).tag(code as String?)
                    }
                }
                .frame(width: 150)

                if canDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Transcription engine picker
            if downloadedEngines.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("No models downloaded. Download a model above to start transcribing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Transcription Model", selection: $mode.transcriptionEngine) {
                    ForEach(downloadedEngines) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
            }

            Picker("Post-processing", selection: $mode.provider) {
                ForEach(LLMProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            if mode.provider != .none {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Search models...", text: $modelSearch)
                            .textFieldStyle(.roundedBorder)
                            .focused($isSearchFocused)
                            .onChange(of: isSearchFocused) {
                                if isSearchFocused && availableModels.isEmpty && !isLoadingModels {
                                    fetchModels()
                                }
                            }

                        if isLoadingModels {
                            ProgressView()
                                .scaleEffect(0.5)
                        }

                        Button {
                            fetchModels()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                    }

                    if let error = modelLoadError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    let filtered = modelSearch.isEmpty ? availableModels :
                        availableModels.filter { $0.localizedCaseInsensitiveContains(modelSearch) }

                    if !filtered.isEmpty && isSearchFocused {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(filtered, id: \.self) { model in
                                    Text(model)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(mode.model == model ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 4))
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            mode.model = model
                                            isSearchFocused = false
                                        }
                                }
                            }
                            .padding(4)
                        }
                        .frame(maxHeight: 120)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let selected = mode.model {
                        Text("Selected: \(selected)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                TextEditor(text: $mode.prompt)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topLeading) {
                        if mode.prompt.isEmpty {
                            Text("System prompt for post-processing")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }

    private var languageBinding: Binding<String?> {
        Binding(
            get: { mode.language },
            set: { mode.language = $0 }
        )
    }

    private func fetchModels() {
        guard mode.provider != .none else { return }
        isLoadingModels = true
        modelLoadError = nil
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
