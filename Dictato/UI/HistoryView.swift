import SwiftUI

struct HistoryView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.transcriptionHistory.isEmpty {
                Text("No transcriptions yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.transcriptionHistory) { item in
                    HistoryRow(item: item)
                        .listRowSeparator(.visible)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
            }
        }
        .frame(width: 600, height: 400)
    }
}

private struct HistoryRow: View {
    let item: Transcription
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(relativeTime(from: item.date))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if let modeName = item.modeName {
                    Text(modeName)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }

                HStack(spacing: 0) {
                    tabButton("Original", tag: 0)
                    tabButton("Post-processed", tag: 1, disabled: true)
                }
                .background(.quaternary, in: Capsule())

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func tabButton(_ label: String, tag: Int, disabled: Bool = false) -> some View {
        Text(label)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(selectedTab == tag ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
            .foregroundStyle(disabled ? .tertiary : (selectedTab == tag ? .primary : .secondary))
            .onTapGesture {
                if !disabled { selectedTab = tag }
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
