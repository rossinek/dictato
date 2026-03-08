import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared

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
        .frame(width: 500, height: 550)
    }
}

private struct ModeRow: View {
    @Binding var mode: TranscriptionMode
    let canDelete: Bool
    let onDelete: () -> Void

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

            TextEditor(text: $mode.prompt)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if mode.prompt.isEmpty {
                        Text("Prompt (for future use)")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.vertical, 4)
    }

    private var languageBinding: Binding<String?> {
        Binding(
            get: { mode.language },
            set: { mode.language = $0 }
        )
    }
}
