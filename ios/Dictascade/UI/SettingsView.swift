import SwiftUI

struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @AppStorage("openai_api_key") private var openAIKey = ""
    @AppStorage("groq_api_key") private var groqKey = ""
    @AppStorage("vocabulary") private var vocabulary = ""
    @AppStorage("iCloudModeSync") private var iCloudModeSync = true
    @State private var pendingConflictItem: PendingConflict?

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

                // iCloud
                VStack(alignment: .leading, spacing: 12) {
                    Text("iCloud")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    Toggle("Sync settings across devices", isOn: $iCloudModeSync)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                        .onChange(of: iCloudModeSync) { _, enabled in
                            if enabled {
                                let sync = ModeSync.shared
                                if let remote = sync.fetchRemote(), remote.deviceID != sync.deviceID {
                                    let conflict = sync.analyzeConflict(local: appState.modes, remote: remote.modes)
                                    if conflict.hasConflict {
                                        iCloudModeSync = false
                                        pendingConflictItem = PendingConflict(conflict: conflict, remoteModes: remote.modes)
                                        return
                                    }
                                } else {
                                    sync.pushModes(appState.modes)
                                }
                                let localVocab = UserDefaults.standard.string(forKey: "vocabulary") ?? ""
                                if !localVocab.isEmpty {
                                    sync.pushVocabulary(localVocab)
                                }
                                sync.start()
                            } else {
                                ModeSync.shared.stop()
                            }
                        }
                }

                // Vocabulary
                VStack(alignment: .leading, spacing: 12) {
                    Text("Vocabulary")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: $vocabulary)
                            .font(.body.monospaced())
                            .frame(minHeight: 80, maxHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .topLeading) {
                                if vocabulary.isEmpty {
                                    Text("One word per line...")
                                        .foregroundStyle(.tertiary)
                                        .font(.body.monospaced())
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 19)
                                        .allowsHitTesting(false)
                                }
                            }
                            .onChange(of: vocabulary) {
                                appState.configureVocabulary(vocabulary)
                                ModeSync.shared.pushVocabulary(vocabulary)
                            }
                        Text("Words to boost during transcription. Use word: alias1, alias2 for alternative spellings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    .padding(16)
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
        .sheet(item: $pendingConflictItem) { item in
            SyncConflictSheet(conflict: item.conflict, remoteModes: item.remoteModes) { resolution in
                let sync = ModeSync.shared
                switch resolution {
                case .useICloud:
                    appState.modes = sync.toLocalModes(item.remoteModes)
                    appState.saveModes()
                case .keepLocal:
                    sync.pushModes(appState.modes)
                case .mergeBoth:
                    appState.modes = sync.mergeModes(local: appState.modes, remote: item.remoteModes)
                    appState.saveModes()
                    sync.pushModes(appState.modes)
                }
                iCloudModeSync = true
                sync.start()
                pendingConflictItem = nil
            }
        }
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
                    .fixedSize()
                Spacer()
                Picker("Provider", selection: $mode.provider) {
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
                .tint(.primary)
            }

            if mode.provider != .none {
                if mode.provider.requiresModel {
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

// MARK: - Sync Conflict Sheet

private struct PendingConflict: Identifiable {
    let id = UUID()
    let conflict: SyncConflict
    let remoteModes: [SharedMode]
}

private enum SyncResolution {
    case useICloud, keepLocal, mergeBoth
}

private struct SyncConflictSheet: View {
    let conflict: SyncConflict
    let remoteModes: [SharedMode]
    let onResolve: (SyncResolution) -> Void

    @Environment(\.dismiss) private var dismiss

    private var localModes: [TranscriptionMode] {
        AppState.shared.modes
    }

    private var mergedNames: [String] {
        let localIDs = Set(localModes.map { $0.id })
        let remoteIDs = Set(remoteModes.map { $0.id })
        let matchingIDs = Set(conflict.matching)

        var names: [String] = []
        for r in remoteModes {
            if matchingIDs.contains(r.id) {
                names.append(r.name)
            } else if localIDs.contains(r.id) {
                names.append("\(r.name) (remote)")
            } else {
                names.append("\(r.name) (remote)")
            }
        }
        for l in localModes where !remoteIDs.contains(l.id) {
            names.append("\(l.name) (local)")
        }
        return names
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Modes differ from iCloud")
                        .font(.headline)
                        .padding(.top, 4)

                    optionButton("Use iCloud", resolution: .useICloud) {
                        ForEach(remoteModes, id: \.id) { mode in
                            Label(mode.name, systemImage: "circle.fill")
                                .font(.callout)
                                .labelStyle(BulletLabelStyle())
                        }
                    }

                    optionButton("Keep Local", resolution: .keepLocal) {
                        ForEach(localModes) { mode in
                            Label(mode.name, systemImage: "circle.fill")
                                .font(.callout)
                                .labelStyle(BulletLabelStyle())
                        }
                    }

                    optionButton("Merge Both", resolution: .mergeBoth) {
                        ForEach(Array(mergedNames.enumerated()), id: \.offset) { _, name in
                            Label(name, systemImage: "circle.fill")
                                .font(.callout)
                                .labelStyle(BulletLabelStyle())
                        }
                    }
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func optionButton<Content: View>(_ title: String, resolution: SyncResolution, @ViewBuilder content: () -> Content) -> some View {
        Button {
            onResolve(resolution)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.callout.weight(.semibold))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .contentShape(Rectangle())
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 4))
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}

// MARK: - Previews

#Preview("Settings") {
    NavigationStack {
        SettingsView()
    }
}
