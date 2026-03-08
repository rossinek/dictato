import SwiftUI

struct RecordingOverlay: View {
    let isRecording: Bool
    let isTranscribing: Bool

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isTranscribing ? Color.orange : Color.red)
                .frame(width: 10, height: 10)
                .scaleEffect(pulse ? 1.3 : 1.0)

            Text(statusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var statusText: String {
        if isTranscribing { return "Transcribing..." }
        return "Recording..."
    }
}
