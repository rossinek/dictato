import KeyboardShortcuts
import SwiftUI

/// What the overlay shows. While the panel hides, AppState is already idle; the
/// overlay keeps the last visible status so it does not flash "Recording..." (and,
/// in the full style, the mode pill) for the moment before the panel disappears.
struct OverlayStatus: Equatable {
    enum Phase: Equatable {
        case recording, paused, transcribing, postProcessing, error
    }

    var phase: Phase
    var errorMessage = ""
    var hasFailedRecording = false
    var microphoneName: String?

    @MainActor init?(_ state: AppState) {
        if state.isError {
            phase = .error
        } else if state.isPaused {
            phase = .paused
        } else if state.isRecording {
            phase = .recording
        } else if state.isPostProcessing {
            phase = .postProcessing
        } else if state.isTranscribing || state.isModelLoading {
            phase = .transcribing
        } else {
            return nil
        }
        errorMessage = state.errorMessage
        hasFailedRecording = state.hasFailedRecording
        microphoneName = phase == .recording || phase == .paused ? state.activeInputDeviceName : nil
    }

    init(phase: Phase) {
        self.phase = phase
    }

    var dotColor: Color {
        switch phase {
        case .error, .recording: .red
        case .paused: .yellow
        case .postProcessing: .blue
        case .transcribing: .orange
        }
    }

    var text: String {
        switch phase {
        case .error: errorMessage.isEmpty ? "Transcription failed" : errorMessage
        case .paused: "Paused"
        case .postProcessing: "Post-processing..."
        case .transcribing: "Transcribing..."
        case .recording: "Recording..."
        }
    }
}

struct RecordingOverlay: View {
    @ObservedObject private var appState = AppState.shared
    @AppStorage(OverlayStyle.defaultsKey) private var style: OverlayStyle = .full
    @State private var lastStatus = OverlayStatus(phase: .recording)

    private var status: OverlayStatus { OverlayStatus(appState) ?? lastStatus }

    var body: some View {
        Group {
            switch style {
            case .full: FullRecordingOverlay(appState: appState, status: status)
            case .mini: MiniRecordingOverlay(appState: appState, status: status)
            }
        }
        .onAppear { if let current = OverlayStatus(appState) { lastStatus = current } }
        .onChange(of: OverlayStatus(appState)) { _, current in
            if let current { lastStatus = current }
        }
    }
}

private struct FullRecordingOverlay: View {
    @ObservedObject var appState: AppState
    let status: OverlayStatus
    @State private var pulse = false

    private var isRecording: Bool { status.phase == .recording }
    private var isPaused: Bool { status.phase == .paused }
    private var isTranscribing: Bool { status.phase == .transcribing }
    private var isPostProcessing: Bool { status.phase == .postProcessing }
    private var isError: Bool { status.phase == .error }

    /// Microphone name above the visualizer, styled like the shortcut descriptions.
    private var microphoneName: String? { status.microphoneName }

    private static let microphoneLabelHeight: CGFloat = 11
    private static let visualizerOverflow: CGFloat = 18
    private static let microphoneLabelSpacing: CGFloat = 4

    private var topPadding: CGFloat { microphoneName == nil ? 20 : 4 }

    private var visualizerTopPadding: CGFloat {
        guard microphoneName != nil else { return topPadding + 3 }
        return topPadding + Self.microphoneLabelHeight + Self.microphoneLabelSpacing + 3
    }

    var body: some View {
        VStack(spacing: 8) {

            // Main pill
            VStack(spacing: 4) {
                if let microphoneName {
                    Text(microphoneName)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220)
                        .frame(height: Self.microphoneLabelHeight)
                        .opacity(0.3)
                        .padding(.bottom, Self.microphoneLabelSpacing - 4)
                }
                if isRecording {
                    // Placeholder to reserve height for the visualizer
                    Color.clear
                        .frame(minWidth: 180)
                        .frame(height: 19)
                } else {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 12, height: 12)
                            .scaleEffect(isPaused || isError ? 1.0 : (pulse ? 1.3 : 1.0))
                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)

                        Text(statusText)
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(height: 19)
                }

                HStack(spacing: 8) {
                    ForEach(actions, id: \.label) { action in
                        HStack(spacing: 4) {
                            Text(action.key)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 0)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))

                            Text(action.label)
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { action.handler() }
                    }
                }.opacity(0.4)
            }
            .padding(.horizontal, 24)
            .padding(.top, topPadding)
            .padding(.bottom, 6)
            .frame(minWidth: 250)
            .fixedSize()
            .overlay(alignment: .top) {
                if isRecording {
                    // The canvas extends beyond the 19 pt band so enlarged edge bars are
                    // not cut off at the band; the pill's capsule shape clips them.
                    AudioVisualizerView(meter: appState.audioLevelMeter, bandHeight: 19)
                        .frame(height: 19 + 2 * Self.visualizerOverflow)
                        .padding(.top, visualizerTopPadding - Self.visualizerOverflow)
                }
            }
            .clipShape(.capsule)
            .glassEffect(.regular, in: .capsule)

            // Mode select pill
            if appState.modes.count > 1 && !isTranscribing && !isPostProcessing && !isError {
                ModeMenuButton(appState: appState)
                    .glassEffect(.regular)
            }
          }
          .onAppear {
              pulse = true
          }
          .onDisappear {
              pulse = false
          }
    }

    private var dotColor: Color { status.dotColor }

    private var statusText: String { status.text }

    private var shortcutLabel: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            return shortcut.description
        }
        return "⌥Space"
    }

    private struct Action {
        let key: String
        let label: String
        let handler: () -> Void
    }

    private var actions: [Action] {
        if isError {
            var errorActions = [
                Action(key: "esc", label: "Dismiss") { AppState.shared.dismissError() },
            ]
            if status.hasFailedRecording {
                errorActions.append(Action(key: "⏎", label: "Save recording") { AppState.shared.saveFailedRecording() })
            }
            return errorActions
        } else if isTranscribing || isPostProcessing {
            return [
                Action(key: "esc", label: "Cancel") { AppState.shared.cancelTranscription() },
            ]
        } else if isPaused {
            return [
                Action(key: "esc", label: "Resume") { AppState.shared.togglePause() },
                Action(key: "⏎", label: "Discard") { AppState.shared.discardRecording() },
            ]
        } else {
            return [
                Action(key: shortcutLabel, label: "Finish") { AppState.shared.toggleRecording() },
                Action(key: "esc", label: "Pause") { AppState.shared.togglePause() },
            ]
        }
    }
}

// MARK: - Mode Menu Button

private struct ModeMenuButton: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Text(appState.selectedMode.name)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
            .onTapGesture { showMenu() }
    }

    private func showMenu() {
        let menu = NSMenu()
        for (index, mode) in appState.modes.enumerated() {
            let item = NSMenuItem(title: mode.name, action: #selector(ModeMenuTarget.selectMode(_:)), keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = []
            item.target = ModeMenuTarget.shared
            item.tag = index
            item.state = appState.selectedModeIndex == index ? .on : .off
            menu.addItem(item)
        }

        FloatingPanel.isMenuOpen = true
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        FloatingPanel.isMenuOpen = false
    }
}

private class ModeMenuTarget: NSObject {
    static let shared = ModeMenuTarget()

    @objc func selectMode(_ sender: NSMenuItem) {
        let index = sender.tag
        Task { @MainActor in
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                AppState.shared.selectMode(index: index)
            }
        }
    }
}

// MARK: - Audio Visualizer

/// Scrolling level bars. Bars sit on a fixed audio-time grid and move at constant
/// speed along a virtual track, so timing does not depend on how audio buffers
/// arrive; each bar shows the mean level of its interval. The track is mapped onto
/// the pill so the middle has constant spacing and speed, while in the edge zones
/// (`edgeZone` of the width on each side) spacing and speed grow toward the edge
/// (bars slow down after entering and speed up before leaving) and bars are
/// enlarged. Drawing runs slightly behind the audio.
struct AudioVisualizerView: View {
    let meter: AudioLevelMeter
    /// Height that a full-scale bar fills; the canvas may be taller so that
    /// enlarged edge bars can extend beyond it.
    let bandHeight: CGFloat
    private let barWidth: CGFloat = 2.5
    private let barPitch: CGFloat = 4.5      // bar width + gap in the middle zone
    private let speed: CGFloat = 80          // points per second in the middle zone
    private let edgeZone: CGFloat = 0.3      // fraction of the width on each side where bars slow down/speed up and are enlarged
    private let edgeStretch: CGFloat = 3     // spacing/speed multiplier at the very edge
    private let maxEdgeScale: CGFloat = 3  // bar height multiplier at the very edge
    private let scaleCurve: CGFloat = 4      // higher = enlargement concentrated closer to the edge
    private let minBarHeight: CGFloat = 2.5
    private let latency: Double = 0.025      // seconds behind the newest audio (buffers arrive every ~11 ms)

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                guard let head = meter.audioTime(at: context.date, latency: latency) else { return }
                let track = Track(width: size.width, edgeZone: edgeZone, edgeStretch: edgeStretch)
                let interval = Double(barPitch / speed)
                let fadeZone: CGFloat = 0.15 // fraction of width for edge fade
                var index = floor(head / interval)

                while true {
                    let time = index * interval
                    // Distance travelled along the track since entering at the right edge.
                    let travelled = CGFloat(head - time) * speed
                    if travelled > track.length { break }
                    index -= 1
                    guard time > 0, travelled >= 0 else { continue }
                    // Audio not delivered yet (e.g. a Bluetooth stall) is drawn as silence
                    // and fills in when the backlog arrives, so bars never jump.
                    let rms = meter.level(from: time - interval, to: time) ?? 0
                    let x = size.width - track.screenDistance(travelled)

                    let level = CGFloat(normalizeLevel(rms))
                    let barHeight = max(minBarHeight, level * bandHeight)

                    let position = x / size.width
                    // Fade only at the exit (left) edge: new bars enter at the right
                    // edge at full opacity so what is said now shows up immediately.
                    let fade = position < fadeZone ? max(0, position / fadeZone) : 1

                    // Enlargement at both edges, growing exponentially toward the edge.
                    let closeness = max(0, 1 - min(position, 1 - position) / edgeZone) // 1 at the edge
                    let growth = (exp(scaleCurve * closeness) - 1) / (exp(scaleCurve) - 1)
                    let scaledHeight = barHeight * (1 + (maxEdgeScale - 1) * growth)
                    let rect = CGRect(
                        x: x - barWidth,
                        y: (size.height - scaledHeight) / 2,
                        width: barWidth,
                        height: scaledHeight
                    )
                    let opacity = (0.3 + Double(level) * 0.7) * Double(fade)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.primary.opacity(opacity)))
                }
            }
        }
    }

    /// Maps distance along the virtual track (constant speed) to distance from the
    /// right edge on screen. Linear in the middle; in each edge zone the slope rises
    /// linearly from 1 at the zone boundary to `edgeStretch` at the edge, so speed
    /// and spacing change smoothly.
    private struct Track {
        let middle: CGFloat     // screen width (= track length) of the middle zone
        let zone: CGFloat       // screen width of one edge zone
        let zoneLength: CGFloat // track length of one edge zone
        let stretch: CGFloat

        init(width: CGFloat, edgeZone: CGFloat, edgeStretch: CGFloat) {
            zone = width * edgeZone
            middle = width - 2 * zone
            stretch = edgeStretch
            // Screen width of a zone = ∫ slope = L + (stretch - 1) * L / 2.
            zoneLength = zone / (1 + (edgeStretch - 1) / 2)
        }

        var length: CGFloat { middle + 2 * zoneLength }

        /// Screen distance covered after `v` track points into a zone, from its inner boundary.
        private func zoneDistance(_ v: CGFloat) -> CGFloat {
            v + (stretch - 1) * v * v / (2 * zoneLength)
        }

        func screenDistance(_ travelled: CGFloat) -> CGFloat {
            if travelled <= zoneLength {
                return zone - zoneDistance(zoneLength - travelled)
            }
            if travelled <= zoneLength + middle {
                return zone + (travelled - zoneLength)
            }
            return zone + middle + zoneDistance(min(travelled - zoneLength - middle, zoneLength))
        }
    }

    private func normalizeLevel(_ level: Float) -> Float {
        guard level > 0 else { return 0 }
        let dbFloor: Float = -50
        let dbCeil: Float = -10
        let db = 20 * log10(level)
        let normalized = (db - dbFloor) / (dbCeil - dbFloor)
        return max(0, min(1, normalized))
    }
}

#Preview {
    VStack(spacing: 0) {
        RecordingOverlay()
            .frame(width: 400, height: 200)
            .background(.black)

        RecordingOverlay()
            .frame(width: 400, height: 200)
            .background(.white)
    }
}
