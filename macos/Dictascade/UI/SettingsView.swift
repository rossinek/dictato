import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var modelManager = AppState.shared.modelManager
    @AppStorage("openai_api_key") private var openAIKey = ""
    @AppStorage("groq_api_key") private var groqKey = ""
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

            // iCloud
            Section("iCloud") {
                Toggle("Sync modes across devices", isOn: $iCloudModeSync)
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
                            sync.start()
                        } else {
                            ModeSync.shared.stop()
                        }
                    }
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
        .sheet(item: $pendingConflictItem) { item in
            SyncConflictSheet(conflict: item.conflict, remoteModes: item.remoteModes) { resolution in
                let sync = ModeSync.shared
                switch resolution {
                case .useICloud:
                    appState.modes = sync.applyEngineMap(item.remoteModes)
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
        let sync = ModeSync.shared
        let localIDs = Set(localModes.map { $0.id })
        let remoteIDs = Set(remoteModes.map { $0.id })
        let matchingIDs = Set(conflict.matching)

        var names: [String] = []
        // Remote-order modes first
        for r in remoteModes {
            if matchingIDs.contains(r.id) {
                names.append(r.name)
            } else if localIDs.contains(r.id) {
                names.append("\(r.name) (remote)")
            } else {
                names.append("\(r.name) (remote)")
            }
        }
        // Local-only modes
        for l in localModes where !remoteIDs.contains(l.id) {
            names.append("\(l.name) (local)")
        }
        return names
    }

    var body: some View {
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

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
        }
        .padding(20)
        .frame(width: 320)
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
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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

// MARK: - Model Row

private struct ModelRow: View {
    let engine: TranscriptionEngine
    @ObservedObject var modelManager: ModelManager
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(engine.displayName)
                        .font(.body.bold())
                    if engine == .fluidAudio {
                        Text("Recommended")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
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

    private var isSelectedEngineDownloaded: Bool {
        modelManager.isDownloaded(mode.transcriptionEngine)
    }

    private var isMissingLLMModel: Bool {
        mode.provider != .none && mode.provider.requiresModel && mode.model == nil
    }

    private var hasAlert: Bool {
        !isSelectedEngineDownloaded || isMissingAPIKey || isMissingLLMModel
    }

    private var isMissingAPIKey: Bool {
        guard mode.provider != .none, mode.provider.baseURL != nil else { return false }
        guard let key = mode.provider.apiKey() else { return true }
        return key.isEmpty
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

                settingsRow("Model") {
                    HStack(spacing: 6) {
                        if !isSelectedEngineDownloaded {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .help("Model not downloaded")
                        }
                        Picker("", selection: $mode.transcriptionEngine) {
                            ForEach(TranscriptionEngine.allCases) { engine in
                                HStack {
                                    Text(engine.displayName)
                                    if !modelManager.isDownloaded(engine) {
                                        Text("(not downloaded)")
                                    }
                                }.tag(engine)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                Divider()

                settingsRow("Post-processing") {
                    HStack(spacing: 6) {
                        if isMissingAPIKey {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .help("API key not set")
                        }
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
                }

                if mode.provider != .none {
                    if mode.provider.requiresModel {
                        Divider()

                        settingsRow("LLM") {
                            HStack(spacing: 6) {
                                if isMissingLLMModel {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                        .help("No model selected")
                                }
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
                if hasAlert {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

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

