import KeyboardShortcuts
import SwiftUI

struct RecordingOverlay: View {
    let isRecording: Bool
    let isPaused: Bool
    let isTranscribing: Bool
    let isPostProcessing: Bool
    let isError: Bool
    @ObservedObject private var appState = AppState.shared
    @State private var pulse = false
@Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {

            // Main pill
            VStack(spacing: 4) {
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
            .padding(.top, 20)
            .padding(.bottom, 6)
            .frame(minWidth: 250)
            .fixedSize()
            .overlay(alignment: .top) {
                if isRecording {
                    AudioVisualizerView(levels: appState.audioLevels)
                        .frame(height: 19)
                        .padding(.top, 23)
                }
            }
            .clipShape(.capsule)
            .glassEffect(.clear, in: .capsule)

            // Mode select pill
            if appState.modes.count > 1 && !isTranscribing && !isPostProcessing && !isError {
                ModeMenuButton(appState: appState)
                    .glassEffect(.clear)
            }
          }
          .onAppear {
              pulse = true
          }
    }

    private var dotColor: Color {
        if isError { return .red }
        if isPaused { return .yellow }
        if isPostProcessing { return .blue }
        if isTranscribing { return .orange }
        return .red
    }

    private var statusText: String {
        if isError {
            let msg = appState.errorMessage
            return msg.isEmpty ? "Transcription failed" : msg
        }
        if isPaused { return "Paused" }
        if isPostProcessing { return "Post-processing..." }
        if isTranscribing { return "Transcribing..." }
        return "Recording..."
    }

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
            if appState.hasFailedRecording {
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

private struct AudioBar: Identifiable {
    let id = UUID()
    let level: Float
    let birthTime: Date
}

private struct AudioVisualizerView: View {
    let levels: [Float]
    private let barWidth: CGFloat = 2.5
    private let minBarHeight: CGFloat = 2.5
    private let travelDuration: TimeInterval = 3.0 // seconds to cross the view

    @State private var bars: [AudioBar] = []

    var body: some View {
        GeometryReader { geo in
            let maxHeight = geo.size.height
            let width = geo.size.width

            TimelineView(.animation) { context in
                let now = context.date

                Canvas { ctx, size in
                    let fadeZone: CGFloat = 0.15 // fraction of width for edge fade

                    for bar in bars {
                        let age = now.timeIntervalSince(bar.birthTime)
                        let progress = age / travelDuration
                        guard progress >= 0 && progress <= 1 else { continue }

                        let eased = easeInOut(Float(progress))
                        let x = width * (1 - CGFloat(eased)) - barWidth / 2
                        let barHeight = max(minBarHeight, CGFloat(bar.level) * maxHeight)
                        let y = (maxHeight - barHeight) / 2

                        // Edge proximity (0 at edge, 1 in center)
                        let posNorm = x / width
                        let edgeProximity: CGFloat
                        if posNorm < fadeZone {
                            edgeProximity = posNorm / fadeZone
                        } else if posNorm > 1 - fadeZone {
                            edgeProximity = (1 - posNorm) / fadeZone
                        } else {
                            edgeProximity = 1
                        }

                        // Vertical scale: 3x at edge, 1x in center
                        let maxScale: CGFloat = 2.0
                        let vScale = 1 + (maxScale - 1) * (1 - edgeProximity)
                        let scaledHeight = barHeight * vScale
                        let scaledY = (maxHeight - scaledHeight) / 2

                        let baseOpacity = 0.3 + Double(bar.level) * 0.7
                        let rect = CGRect(x: x, y: scaledY, width: barWidth, height: scaledHeight)
                        let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                        ctx.fill(path, with: .color(.white.opacity(baseOpacity * Double(edgeProximity))))
                    }
                }
                .frame(width: width, height: maxHeight)
            }
        }
        .onChange(of: levels) {
            let now = Date.now

            // Spawn one bar for the newest sample
            if let last = levels.last {
                bars.append(AudioBar(level: normalizeLevel(last), birthTime: now))
            }

            // Prune bars that have exited
            bars.removeAll { now.timeIntervalSince($0.birthTime) > travelDuration }
        }
    }

    /// Fast at edges, slow (but never zero) in middle
    private func easeInOut(_ t: Float) -> Float {
        // Symmetric curve: fast at 0 and 1, slowest at 0.5
        // f(t) using smoothstep inverse concept
        if t < 0.5 {
            // Fast deceleration: sqrt curve (fast start, slows down)
            return 0.5 * pow(2 * t, 0.6)
        } else {
            // Mirror: accelerates toward exit
            return 1 - 0.5 * pow(2 * (1 - t), 0.6)
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

#Preview("Recording") {
    VStack(spacing: 0) {
        RecordingOverlay(
            isRecording: true, isPaused: false, isTranscribing: false, isPostProcessing: false, isError: false
        )
        .frame(width: 400, height: 200)
        .background(.black)

        RecordingOverlay(
            isRecording: true, isPaused: false, isTranscribing: false, isPostProcessing: false, isError: false
        )
        .frame(width: 400, height: 200)
        .background(.white)
    }
}

#Preview("Paused") {
    HStack(spacing: 0) {
        RecordingOverlay(
            isRecording: false, isPaused: true, isTranscribing: false, isPostProcessing: false, isError: false
        )
        .frame(width: 400, height: 200)
        .background(.black)

        RecordingOverlay(
            isRecording: false, isPaused: true, isTranscribing: false, isPostProcessing: false, isError: false
        )
        .frame(width: 400, height: 200)
        .background(.white)
    }
}

#Preview("Transcribing") {
    HStack(spacing: 0) {
        RecordingOverlay(
            isRecording: false, isPaused: false, isTranscribing: true, isPostProcessing: false, isError: false
        )
        .frame(width: 400, height: 200)
        .background(.black)

        RecordingOverlay(
            isRecording: false, isPaused: false, isTranscribing: true, isPostProcessing: false, isError: false
        )
        .frame(width: 400, height: 200)
        .background(.white)
    }
}
