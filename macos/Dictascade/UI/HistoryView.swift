import SwiftUI

struct HistoryView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            if appState.transcriptionHistory.isEmpty {
                Text("No transcriptions yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                LazyVStack(spacing: 16) {
                    ForEach(appState.transcriptionHistory) { item in
                        HistoryRow(item: item, appState: appState)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HistoryRow: View {
    let item: Transcription
    @ObservedObject var appState: AppState
    @State private var selectedTab: Int
    @Namespace private var pillNamespace

    init(item: Transcription, appState: AppState) {
        self.item = item
        self.appState = appState
        self._selectedTab = State(initialValue: item.postProcessedText != nil ? 1 : 0)
    }

    private var hasAudio: Bool {
        appState.audioFileURL(for: item) != nil
    }

    private var isReTranscribing: Bool {
        appState.reTranscribingID == item.id
    }

    private var displayedText: String {
        if selectedTab == 1, let processed = item.postProcessedText {
            return processed
        }
        return item.text
    }

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 10) {
                // Timestamp
                Text(relativeTime(from: item.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Transcription text
                Text(displayedText)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Bottom row
                HStack(spacing: 4) {
                    // Mode pill menu
                    if isReTranscribing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    } else if hasAudio {
                        Menu {
                            ForEach(appState.modes) { mode in
                                Button(mode.name) {
                                    appState.reTranscribe(transcriptionID: item.id, withMode: mode)
                                }
                            }
                        } label: {
                            Text((item.modeName ?? "Default") + "  ❯")
                                .font(.caption)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    } else if let modeName = item.modeName {
                        Text(modeName)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)
                    }

                    // Original / Post-processed pills
                    if item.postProcessedText != nil {
                        HStack(spacing: 2) {
                            ForEach([(0, "Original"), (1, "Post-processed")], id: \.0) { tag, label in
                                Text(label)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                                    .background {
                                        if selectedTab == tag {
                                            Capsule()
                                                .fill(.white.opacity(0.12))
                                                .matchedGeometryEffect(id: "tab-\(item.id)", in: pillNamespace)
                                        }
                                    }
                                    .foregroundStyle(selectedTab == tag ? .primary : .secondary)
                                    .contentShape(Capsule())
                                    .onTapGesture {
                                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                                            selectedTab = tag
                                        }
                                    }
                            }
                        }
                        .padding(3)
                        .glassEffect(.regular, in: .capsule)
                    }

                    Spacer()

                    // Delete
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            appState.deleteTranscription(id: item.id)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(.red.opacity(0.7))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)

                    // Save audio
                    if hasAudio {
                        Button {
                            saveAudioFile()
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                    }

                    // Copy
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(displayedText, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                }
            }
            .padding(16)
            .contentShape(.rect(cornerRadius: 14))
            .glassEffect(.clear, in: .rect(cornerRadius: 14))
        }
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(displayedText, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            if hasAudio {
                Button {
                    saveAudioFile()
                } label: {
                    Label("Save Audio", systemImage: "arrow.down.circle")
                }
            }
            Divider()
            Button(role: .destructive) {
                withAnimation(.spring(duration: 0.3)) {
                    appState.deleteTranscription(id: item.id)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func saveAudioFile() {
        guard let sourceURL = appState.audioFileURL(for: item) else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.wav]
        savePanel.nameFieldStringValue = "recording-\(Int(item.date.timeIntervalSince1970)).wav"
        guard savePanel.runModal() == .OK, let destURL = savePanel.url else { return }
        try? FileManager.default.copyItem(at: sourceURL, to: destURL)
    }

    private func relativeTime(from date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "Just now" }
        let minutes = seconds / 60
        if minutes == 1 { return "1 minute ago" }
        if minutes < 60 { return "\(minutes) minutes ago" }
        let hours = minutes / 60
        if hours == 1 { return "1 hour ago" }
        if hours < 24 { return "\(hours) hours ago" }
        let days = hours / 24
        if days == 1 { return "1 day ago" }
        return "\(days) days ago"
    }
}

#if DEBUG
#Preview("History") {
    HistoryView(appState: .preview())
        .frame(width: 620, height: 450)
}

#Preview("Empty") {
    HistoryView(appState: {
        let s = AppState.preview()
        s.transcriptionHistory = []
        return s
    }())
    .frame(width: 620, height: 450)
}
#endif
