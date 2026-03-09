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
        Form {
            Section("API Keys") {
                SecureField("OpenAI API Key", text: $openAIKey)
                SecureField("Groq API Key", text: $groqKey)
            }

            Section("Keyboard Shortcut") {
                KeyboardShortcuts.Recorder("Toggle Recording:", name: .toggleRecording)
            }

            Section("Modes") {
                ForEach(appState.modes) { mode in
                    if let index = appState.modes.firstIndex(where: { $0.id == mode.id }) {
                        ModeRow(
                            mode: Binding(
                                get: { appState.modes[index] },
                                set: {
                                    appState.modes[index] = $0
                                    appState.saveModes()
                                }
                            ),
                            canDelete: appState.modes.count > 1,
                            onDelete: {
                                appState.modes.remove(at: index)
                                if appState.selectedModeIndex >= appState.modes.count {
                                    appState.selectedModeIndex = 0
                                }
                                appState.saveModes()
                            }
                        )
                    }
                }

                Button("Add Mode") {
                    let mode = TranscriptionMode(
                        id: UUID(),
                        name: "Mode \(appState.modes.count + 1)",
                        language: nil,
                        prompt: ""
                    )
                    appState.modes.append(mode)
                    appState.saveModes()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 550, height: 650)
    }
}

private struct ModeRow: View {
    @Binding var mode: TranscriptionMode
    let canDelete: Bool
    let onDelete: () -> Void

    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                HStack {
                    Picker("Model", selection: modelBinding) {
                        Text("Select a model").tag(nil as String?)
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model as String?)
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

                TextEditor(text: $mode.prompt)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if mode.prompt.isEmpty {
                            Text("System prompt for post-processing")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: mode.provider) {
            availableModels = []
            mode.model = nil
            modelLoadError = nil
            if mode.provider != .none {
                fetchModels()
            }
        }
        .onAppear {
            if mode.provider != .none {
                fetchModels()
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
