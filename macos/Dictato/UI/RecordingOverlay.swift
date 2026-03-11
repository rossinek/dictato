import KeyboardShortcuts
import SwiftUI

struct PillSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct RecordingOverlay: View {
    let isRecording: Bool
    let isPaused: Bool
    let isTranscribing: Bool
    let isPostProcessing: Bool
    let isError: Bool
    @ObservedObject private var appState = AppState.shared
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 8) {

            // Main pill
            VStack(spacing: 6) {
                if isRecording {
                    AudioVisualizerView(levels: appState.audioLevels)
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

                HStack(spacing: 16) {
                    ForEach(actions, id: \.label) { action in
                        HStack(spacing: 4) {
                            Text(action.key)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))

                            Text(action.label)
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { action.handler() }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .frame(minWidth: 250)
            .fixedSize()
            .overlay(GeometryReader { geo in
                Color.clear.preference(key: PillSizeKey.self, value: geo.size)
            })
            .glassEffect(.clear, in: .capsule)

            // Mode pills — separate row below, centered
            if appState.modes.count > 1 && !isTranscribing && !isPostProcessing && !isError {
              GlassEffectContainer(spacing: 7) {
                HStack(spacing: 0) {
                  ForEach(Array(appState.modes.enumerated()), id: \.element.id) { index, mode in
                    let isSelected = index == appState.selectedModeIndex
                    HStack(spacing: 5) {
                      Text("\(index + 1)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))

                      Text(mode.name)
                        .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(
                      .clear,
                      in: .capsule
                    )
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .contentShape(Capsule())
                    .onTapGesture { AppState.shared.selectMode(index: index) }
                  }
                }
              }
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
        if isError { return "Transcription failed" }
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
            return [
                Action(key: "esc", label: "Dismiss") { AppState.shared.dismissError() },
                Action(key: "⏎", label: "Save recording") { AppState.shared.saveFailedRecording() },
            ]
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

// MARK: - Audio Visualizer

private struct AudioVisualizerView: View {
    let levels: [Float]
    private let barSpacing: CGFloat = 2
    private let barWidth: CGFloat = 2.5
    private let minBarHeight: CGFloat = 2.5 // matches barWidth for circular dot
    private let referenceLevel: Float = 0.12

    @State private var currentLevels: [Float] = []
    @State private var lastUpdateTime: Date = .now
    @State private var averageInterval: TimeInterval = 0.1
    @State private var smoothedPeak: Float = 0.01
    @State private var noiseFloor: Float = 0

    var body: some View {
        GeometryReader { geo in
            let barCount = max(1, Int(geo.size.width / (barWidth + barSpacing)))
            let maxHeight = geo.size.height

            TimelineView(.animation) { context in
                let interpolated = interpolatedLevels(at: context.date, barCount: barCount)

                HStack(spacing: barSpacing) {
                    ForEach(0..<interpolated.count, id: \.self) { i in
                        let level = interpolated[i]
                        let barHeight = max(minBarHeight, CGFloat(level) * maxHeight)

                        RoundedRectangle(cornerRadius: barWidth / 2)
                            .fill(.white.opacity(0.3 + Double(level) * 0.7))
                            .frame(width: barWidth, height: barHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: levels) {
            let now = Date.now
            let interval = now.timeIntervalSince(lastUpdateTime)
            if interval > 0.01 && interval < 1.0 {
                // Smooth the interval estimate
                averageInterval = averageInterval * 0.7 + interval * 0.3
            }
            lastUpdateTime = now
            currentLevels = normalizedLevels()
        }
    }

    /// Each frame: blend bar[i] toward bar[i+1] based on time progress between data updates
    private func interpolatedLevels(at date: Date, barCount: Int) -> [Float] {
        let source = currentLevels
        guard !source.isEmpty else { return Array(repeating: 0, count: barCount) }

        let elapsed = date.timeIntervalSince(lastUpdateTime)
        let t = Float(min(max(elapsed / averageInterval, 0), 1))

        // Blend each bar toward its right neighbor
        var result = [Float](repeating: 0, count: source.count)
        for i in 0..<source.count {
            if i == source.count - 1 {
                result[i] = source[i]
            } else {
                result[i] = source[i] * (1 - t) + source[i + 1] * t
            }
        }

        if result.count > barCount {
            return Array(result.suffix(barCount))
        }
        return result
    }

    private func normalizedLevels() -> [Float] {
        let sourceCount = 48
        var source: [Float]
        if levels.count < sourceCount {
            source = Array(repeating: Float(0), count: sourceCount - levels.count) + levels
        } else {
            source = Array(levels.suffix(sourceCount))
        }

        // Fixed dB scale — no normalization needed
        let dbFloor: Float = -50  // silence threshold
        let dbCeil: Float = -10   // loud speech
        let dbRange = dbCeil - dbFloor

        return source.map { level in
            guard level > 0 else { return Float(0) }
            let db = 20 * log10(level)
            let normalized = (db - dbFloor) / dbRange
            return max(0, min(1, normalized))
        }
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
