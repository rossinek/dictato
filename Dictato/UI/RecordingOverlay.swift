import KeyboardShortcuts
import SwiftUI

struct RecordingOverlay: View {
    let isRecording: Bool
    let isPaused: Bool
    let isTranscribing: Bool
    let isPostProcessing: Bool
    let modes: [TranscriptionMode]
    let selectedModeIndex: Int

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 8) {
            // Main pill
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 12, height: 12)
                        .scaleEffect(isPaused ? 1.0 : (pulse ? 1.3 : 1.0))
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)

                    Text(statusText)
                        .font(.system(size: 16, weight: .semibold))
                }

                if !isTranscribing {
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
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(width: 360, height: 90)
            .glassEffect(.clear.interactive(), in: .capsule)

            // Mode pills — separate row below, centered
            if modes.count > 1 && !isTranscribing {
                HStack(spacing: 6) {
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
                            isSelected ? .clear.interactive() : .clear,
                            in: .capsule
                        )
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .contentShape(Capsule())
                        .onTapGesture { AppState.shared.selectMode(index: index) }
                    }
                }
            }
        }
        .onAppear {
            pulse = true
        }
    }

    private var dotColor: Color {
        if isPaused { return .yellow }
        if isPostProcessing { return .blue }
        if isTranscribing { return .orange }
        return .red
    }

    private var statusText: String {
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
        if isPaused {
            return [
                Action(key: shortcutLabel, label: "Transcribe") { AppState.shared.toggleRecording() },
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
