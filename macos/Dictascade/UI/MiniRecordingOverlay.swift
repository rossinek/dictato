import SwiftUI

/// Recording overlay style (Settings → Recording Overlay).
enum OverlayStyle: String, CaseIterable, Identifiable {
    case full
    case mini

    static let defaultsKey = "overlayStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "Full"
        case .mini: "Mini"
        }
    }
}

/// Compact overlay: a small pill with the visualizer while recording and a status
/// dot otherwise. Elements keep fixed slots (cancel/dismiss left, dot centered, save
/// right), so nothing shifts and the pill never changes size between states.
struct MiniRecordingOverlay: View {
    @ObservedObject var appState: AppState
    @State private var pulse = false
    @State private var isHovering = false
    @State private var flashedModeName: String?
    @State private var flashTask: Task<Void, Never>?

    static let size = CGSize(width: 76, height: 32)
    private static let slotWidth: CGFloat = 22
    private static let visualizerBand: CGFloat = 19
    private static let visualizerOverflow: CGFloat = 18

    private var isRecording: Bool { appState.isRecording }
    private var isError: Bool { appState.isError }

    var body: some View {
        ZStack {
            if isRecording {
                // Same bar size as the full pill; the capsule clips enlarged edge bars.
                AudioVisualizerView(meter: appState.audioLevelMeter, bandHeight: Self.visualizerBand)
                    .frame(width: Self.size.width, height: Self.visualizerBand + 2 * Self.visualizerOverflow)
            } else {
                statusRow
            }

            if isRecording && isHovering && flashedModeName == nil {
                recordingActions
                    .transition(.opacity)
            }

            if let flashedModeName {
                ZStack {
                    Rectangle().fill(.background.opacity(0.55))
                    Text(flashedModeName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 8)
                }
                .transition(.opacity)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(.capsule)
        .glassEffect(.regular, in: .capsule)
        .contentShape(.capsule)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .onChange(of: appState.selectedModeIndex) { flashModeName() }
        .onAppear { pulse = true }
        .onDisappear {
            pulse = false
            flashTask?.cancel()
        }
    }

    // MARK: - Status (paused, transcribing, post-processing, error)

    private var statusRow: some View {
        HStack(spacing: 0) {
            slot {
                iconButton("xmark", help: cancelHelp, action: cancel)
            }
            slot {
                Circle()
                    .fill(RecordingOverlay.dotColor(for: appState))
                    .frame(width: 10, height: 10)
                    .scaleEffect(appState.isPaused || isError ? 1.0 : (pulse ? 1.3 : 1.0))
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .help(RecordingOverlay.statusText(for: appState))
            }
            slot {
                if isError && appState.hasFailedRecording {
                    Button { appState.saveFailedRecording() } label: {
                        FloppyDiskIcon()
                            .frame(width: 11, height: 11)
                            .foregroundStyle(.secondary)
                            .frame(width: Self.slotWidth, height: Self.slotWidth)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Save recording")
                } else {
                    // Keeps three slots so the dot stays centered.
                    Color.clear
                }
            }
        }
    }

    private var cancelHelp: String {
        if isError { return "Dismiss" }
        if appState.isPaused { return "Discard recording" }
        return "Cancel"
    }

    private func cancel() {
        if isError {
            appState.dismissError()
        } else if appState.isPaused {
            appState.discardRecording()
        } else {
            appState.cancelTranscription()
        }
    }

    // MARK: - Recording hover actions

    private var recordingActions: some View {
        ZStack {
            Rectangle().fill(.background.opacity(0.55))
            HStack(spacing: 0) {
                slot { iconButton("xmark", help: "Discard recording") { appState.discardRecording() } }
                Spacer(minLength: 0)
                slot { iconButton("checkmark", help: "Finish") { appState.toggleRecording() } }
            }
            .padding(.horizontal, (Self.size.width - 3 * Self.slotWidth) / 2)
        }
    }

    // MARK: - Mode name flash

    private func flashModeName() {
        flashTask?.cancel()
        let name = appState.selectedMode.name
        withAnimation(.easeIn(duration: 0.15)) { flashedModeName = name }
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { flashedModeName = nil }
        }
    }

    // MARK: - Helpers

    private func slot(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(width: Self.slotWidth, height: Self.slotWidth)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: Self.slotWidth, height: Self.slotWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Floppy disk glyph (SF Symbols has none): body with a clipped top-right corner,
/// a shutter at the top and a label area at the bottom.
struct FloppyDiskIcon: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let line = max(1, w * 0.12)
            ZStack(alignment: .topLeading) {
                FloppyBody(corner: w * 0.24)
                    .stroke(style: StrokeStyle(lineWidth: line, lineJoin: .round))
                Rectangle()
                    .frame(width: w * 0.4, height: w * 0.3)
                    .offset(x: w * 0.25)
                RoundedRectangle(cornerRadius: w * 0.05)
                    .stroke(lineWidth: line)
                    .frame(width: w * 0.56, height: w * 0.42)
                    .offset(x: w * 0.22, y: w * 0.58)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct FloppyBody: Shape {
    let corner: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + corner))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
