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
    let modes: [TranscriptionMode]
    let selectedModeIndex: Int
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 8) {

            // Main pill
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 12, height: 12)
                        .scaleEffect(isPaused || isError ? 1.0 : (pulse ? 1.3 : 1.0))
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)

                    Text(statusText)
                        .font(.system(size: 16, weight: .semibold))
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
            if modes.count > 1 && !isTranscribing && !isPostProcessing && !isError {
              GlassEffectContainer(spacing: 7) {
                HStack(spacing: 0) {
                  ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                    let isSelected = index == selectedModeIndex
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

#Preview("Recording") {
    let modes = [
        TranscriptionMode(id: UUID(), name: "Default", language: nil, prompt: ""),
        TranscriptionMode(id: UUID(), name: "Email", language: "en", prompt: "Format as email"),
    ]
    VStack(spacing: 0) {
        RecordingOverlay(
            isRecording: true, isPaused: false, isTranscribing: false, isPostProcessing: false, isError: false,
            modes: modes, selectedModeIndex: 0
        )
        .frame(width: 400, height: 200)
        .background(.black)

        RecordingOverlay(
            isRecording: true, isPaused: false, isTranscribing: false, isPostProcessing: false, isError: false,
            modes: modes, selectedModeIndex: 0
        )
        .frame(width: 400, height: 200)
        .background(.white)
    }
}

#Preview("Paused") {
    let mode = [TranscriptionMode(id: UUID(), name: "Default", language: nil, prompt: "")]
    HStack(spacing: 0) {
        RecordingOverlay(
            isRecording: false, isPaused: true, isTranscribing: false, isPostProcessing: false, isError: false,
            modes: mode, selectedModeIndex: 0
        )
        .frame(width: 400, height: 200)
        .background(.black)

        RecordingOverlay(
            isRecording: false, isPaused: true, isTranscribing: false, isPostProcessing: false, isError: false,
            modes: mode, selectedModeIndex: 0
        )
        .frame(width: 400, height: 200)
        .background(.white)
    }
}

#Preview("Transcribing") {
    let mode = [TranscriptionMode(id: UUID(), name: "Default", language: nil, prompt: "")]
    HStack(spacing: 0) {
        RecordingOverlay(
            isRecording: false, isPaused: false, isTranscribing: true, isPostProcessing: false, isError: false,
            modes: mode, selectedModeIndex: 0
        )
        .frame(width: 400, height: 200)
        .background(.black)

        RecordingOverlay(
            isRecording: false, isPaused: false, isTranscribing: true, isPostProcessing: false, isError: false,
            modes: mode, selectedModeIndex: 0
        )
        .frame(width: 400, height: 200)
        .background(.white)
    }
}
