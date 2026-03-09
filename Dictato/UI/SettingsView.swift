import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared
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
                // Header
                Text("Settings")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

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
        .frame(width: 550, height: 650)
    }
}

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

private struct ModeRow: View {
    @Binding var mode: TranscriptionMode
    let canDelete: Bool
    let onDelete: () -> Void

    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    @State private var modelSearch = ""
    @FocusState private var isSearchFocused: Bool

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
