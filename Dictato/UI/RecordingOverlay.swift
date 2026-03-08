import KeyboardShortcuts
import SwiftUI

struct RecordingOverlay: View {
    let isRecording: Bool
    let isPaused: Bool
    let isTranscribing: Bool

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            // Status
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .scaleEffect(isPaused ? 1.0 : (pulse ? 1.3 : 1.0))

                Text(statusText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !isTranscribing {
                Divider()
                    .background(.white.opacity(0.2))

                // Actions footer
                HStack(spacing: 16) {
                    ForEach(actions, id: \.label) { action in
                        HStack(spacing: 4) {
                            Text(action.key)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))

                            Text(action.label)
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var dotColor: Color {
        if isPaused { return .yellow }
        if isTranscribing { return .orange }
        return .red
    }

    private var statusText: String {
        if isPaused { return "Paused" }
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
    }

    private var actions: [Action] {
        if isPaused {
            return [
                Action(key: shortcutLabel, label: "Transcribe"),
                Action(key: "esc", label: "Resume"),
                Action(key: "⏎", label: "Discard"),
            ]
        } else {
            return [
                Action(key: shortcutLabel, label: "Finish"),
                Action(key: "esc", label: "Pause"),
            ]
        }
    }
}
