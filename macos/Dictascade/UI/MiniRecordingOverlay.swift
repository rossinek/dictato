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
/// dot otherwise. Actions appear only on hover, over a light overlay, in fixed slots
/// (cancel/dismiss left, save right), so nothing shifts and the pill never resizes.
struct MiniRecordingOverlay: View {
    @ObservedObject var appState: AppState
    let status: OverlayStatus
    @State private var pulse = false
    @State private var isHovering = false
    @State private var flashedModeName: String?
    @State private var flashTask: Task<Void, Never>?

    static let size = CGSize(width: 76, height: 32)
    private static let slotWidth: CGFloat = 22
    private static let visualizerBand: CGFloat = 19
    private static let visualizerOverflow: CGFloat = 18

    private var phase: OverlayStatus.Phase { status.phase }

    var body: some View {
        ZStack {
            if phase == .recording {
                // Same bar size as the full pill; the capsule clips enlarged edge bars.
                AudioVisualizerView(meter: appState.audioLevelMeter, bandHeight: Self.visualizerBand)
                    .frame(width: Self.size.width, height: Self.visualizerBand + 2 * Self.visualizerOverflow)
            } else {
                Circle()
                    .fill(status.dotColor)
                    .frame(width: 10, height: 10)
                    .scaleEffect(phase == .paused || phase == .error ? 1.0 : (pulse ? 1.3 : 1.0))
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            }

            if isHovering && flashedModeName == nil {
                actions
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
        .help(phase == .recording ? "" : status.text)
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

    // MARK: - Hover actions

    private var actions: some View {
        ZStack {
            Rectangle().fill(.background.opacity(0.55))
            HStack(spacing: 0) {
                slot { iconButton("xmark", help: cancelHelp, action: cancel) }
                Spacer(minLength: 0)
                slot {
                    switch phase {
                    case .recording:
                        iconButton("checkmark", help: "Finish") { appState.toggleRecording() }
                    case .error where status.hasFailedRecording:
                        Button { appState.saveFailedRecording() } label: {
                            FloppyDiskIcon()
                                .frame(width: 10, height: 10)
                                .foregroundStyle(.secondary)
                                .frame(width: Self.slotWidth, height: Self.slotWidth)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Save recording")
                    default:
                        Color.clear
                    }
                }
            }
            .padding(.horizontal, (Self.size.width - 3 * Self.slotWidth) / 2)
        }
    }

    private var cancelHelp: String {
        switch phase {
        case .error: "Dismiss"
        case .recording, .paused: "Discard recording"
        case .transcribing, .postProcessing: "Cancel"
        }
    }

    private func cancel() {
        switch phase {
        case .error: appState.dismissError()
        case .recording, .paused: appState.discardRecording()
        case .transcribing, .postProcessing: appState.cancelTranscription()
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
