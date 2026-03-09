import SwiftUI

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
            }
        }
        .navigationTitle("Settings")
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
    @State private var showModelList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Name", text: $mode.name)

                if canDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }

            Picker("Language", selection: languageBinding) {
                ForEach(SettingsView.languages, id: \.0) { code, name in
                    Text(name).tag(code as String?)
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
                            .onTapGesture {
                                if availableModels.isEmpty && !isLoadingModels {
                                    fetchModels()
                                }
                                showModelList = true
                            }

                        if isLoadingModels {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button {
                            fetchModels()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }

                    if let error = modelLoadError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if showModelList {
                        let filtered = modelSearch.isEmpty ? availableModels :
                            availableModels.filter { $0.localizedCaseInsensitiveContains(modelSearch) }

                        if !filtered.isEmpty {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(filtered, id: \.self) { model in
                                        Text(model)
                                            .font(.system(.body, design: .monospaced))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 6)
                                            .background(mode.model == model ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                mode.model = model
                                                showModelList = false
                                            }
                                    }
                                }
                                .padding(4)
                            }
                            .frame(maxHeight: 150)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
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
