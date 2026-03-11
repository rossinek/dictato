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
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("History")
    }
}

private struct HistoryRow: View {
    let item: Transcription
    @ObservedObject var appState: AppState
    @State private var selectedTab: Int
    @State private var showShareSheet = false
    @State private var swipeOffset: CGFloat = 0
    @State private var isSwiped = false

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
        VStack(alignment: .leading, spacing: 10) {
            // Timestamp
            Text(relativeTime(from: item.date))
                .font(.caption)
                .foregroundStyle(.secondary)

            // Transcription text
            Text(displayedText)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Bottom row: dropdowns + download
            HStack(spacing: 8) {
                // Mode dropdown
                if isReTranscribing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else if hasAudio {
                    Menu {
                        ForEach(appState.modes) { mode in
                            Button(mode.name) {
                                appState.reTranscribe(transcriptionID: item.id, withMode: mode)
                            }
                        }
                    } label: {
                        Label(item.modeName ?? "Default", systemImage: "chevron.up.chevron.down")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .glassEffect(.regular.interactive())
                } else if let modeName = item.modeName {
                    Text(modeName)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassEffect(.regular)
                }

                // Original / Post-processed dropdown
                if item.postProcessedText != nil {
                    Menu {
                        Button {
                            selectedTab = 0
                        } label: {
                            Label("Original", systemImage: selectedTab == 0 ? "checkmark" : "")
                        }
                        Button {
                            selectedTab = 1
                        } label: {
                            Label("Post-processed", systemImage: selectedTab == 1 ? "checkmark" : "")
                        }
                    } label: {
                        Label(selectedTab == 0 ? "Original" : "Post-processed", systemImage: "chevron.up.chevron.down")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .glassEffect(.regular.interactive())
                }

                Spacer()

                // Download button
                if hasAudio {
                    Button {
                        showShareSheet = true
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                }
            }
        }
        .padding(16)
        .contentShape(.rect(cornerRadius: 16))
        .glassEffect(.clear, in: .rect(cornerRadius: 16))
        .offset(x: swipeOffset)
        .background(alignment: .trailing) {
            if swipeOffset < 0 {
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        appState.deleteTranscription(id: item.id)
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 20))
                        Text("Delete")
                            .font(.caption2)
                    }
                    .fixedSize()
                    .foregroundStyle(.white)
                    .frame(width: -swipeOffset)
                    .padding(.vertical, 20)
                }
                .background(Color.red)
                .clipShape(.rect(cornerRadius: 16))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    if value.translation.width < 0 || isSwiped {
                        swipeOffset = isSwiped
                            ? min(0, -80 + value.translation.width)
                            : min(0, value.translation.width)
                    }
                }
                .onEnded { value in
                    withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                        if value.translation.width < -40 && !isSwiped {
                            swipeOffset = -80
                            isSwiped = true
                        } else if isSwiped && value.translation.width > 40 {
                            swipeOffset = 0
                            isSwiped = false
                        } else if isSwiped {
                            swipeOffset = -80
                        } else {
                            swipeOffset = 0
                        }
                    }
                }
        )
        .contextMenu {
            Button {
                UIPasteboard.general.string = displayedText
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                appState.deleteTranscription(id: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = appState.audioFileURL(for: item) {
                ShareSheet(activityItems: [url])
            }
        }
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

// MARK: - Previews

#Preview("History") {
    NavigationStack {
        HistoryView(appState: .preview())
    }
}

#Preview("Empty") {
    NavigationStack {
        HistoryView(appState: {
            let s = AppState.preview()
            s.transcriptionHistory = []
            return s
        }())
    }
}
