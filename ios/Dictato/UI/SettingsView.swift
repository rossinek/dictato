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
        ScrollView {
            VStack(spacing: 24) {
                // API Keys
                VStack(alignment: .leading, spacing: 12) {
                    Text("API Keys")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        apiKeyRow(title: "OpenAI", text: $openAIKey)
                        Divider().padding(.leading, 16)
                        apiKeyRow(title: "Groq", text: $groqKey)
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                }

                // Modes
                VStack(alignment: .leading, spacing: 12) {
                    Text("Modes")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    ForEach(appState.modes) { mode in
                        let modeID = mode.id
                        ModeCard(
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
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .navigationTitle("Settings")
    }

    private func apiKeyRow(title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
                .frame(width: 60, alignment: .leading)
            SecureField("API Key", text: text)
                .textContentType(.password)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Mode Card

private struct ModeCard: View {
    @Binding var mode: TranscriptionMode
    let canDelete: Bool
    let onDelete: () -> Void

    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    @State private var showModelPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Name + delete
            HStack {
                TextField("Mode name", text: $mode.name)
                    .font(.body.weight(.medium))

                if canDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(.red)
                    }
                }
            }

            Divider()

            // Language picker
            HStack {
                Text("Language")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Language", selection: languageBinding) {
                    ForEach(SettingsView.languages, id: \.0) { code, name in
                        Text(name).tag(code as String?)
                    }
                }
                .labelsHidden()
                .tint(.primary)
            }

            Divider()

            // Post-processing picker
            HStack {
                Text("Post-processing")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Provider", selection: $mode.provider) {
                    ForEach(LLMProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .tint(.primary)
            }

            if mode.provider != .none {
                Divider()

                // Model selector
                HStack {
                    Text("Model")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        if availableModels.isEmpty && !isLoadingModels {
                            fetchModels()
                        }
                        showModelPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            if isLoadingModels {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(mode.model ?? "Select model")
                                .foregroundStyle(mode.model != nil ? .primary : .secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .sheet(isPresented: $showModelPicker) {
                    ModelPickerSheet(
                        models: availableModels,
                        selected: $mode.model,
                        isLoading: isLoadingModels,
                        error: modelLoadError,
                        onRefresh: { fetchModels() }
                    )
                    .presentationDetents([.medium, .large])
                }

                Divider()

                // Prompt
                VStack(alignment: .leading, spacing: 6) {
                    Text("System prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $mode.prompt)
                        .font(.body)
                        .frame(minHeight: 80, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topLeading) {
                            if mode.prompt.isEmpty {
                                Text("Instructions for post-processing...")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 19)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
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

// MARK: - Model Picker Sheet

private struct ModelPickerSheet: View {
    let models: [String]
    @Binding var selected: String?
    let isLoading: Bool
    let error: String?
    let onRefresh: () -> Void
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [String] {
        search.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && models.isEmpty {
                    ProgressView("Loading models...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 12) {
                        Text(error)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry", action: onRefresh)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, id: \.self) { model in
                        Button {
                            selected = model
                            dismiss()
                        } label: {
                            HStack {
                                Text(model)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selected == model {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Settings") {
    NavigationStack {
        SettingsView()
    }
}
