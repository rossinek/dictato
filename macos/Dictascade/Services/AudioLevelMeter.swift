import Combine
import Foundation

enum AudioLevelEvent: Equatable {
    case reset(sequence: UInt64)
    case level(sequence: UInt64, rms: Float)
}

/// A separate observable for high-frequency microphone level updates.
///
/// Keeping these events out of AppState prevents every view that observes the
/// application state (including the full transcription history) from being
/// invalidated for every incoming audio buffer.
@MainActor
final class AudioLevelMeter: ObservableObject {
    @Published private(set) var event: AudioLevelEvent = .reset(sequence: 0)

    private var sequence: UInt64 = 0

    func reset() {
        sequence &+= 1
        event = .reset(sequence: sequence)
    }

    func update(rms: Float) {
        sequence &+= 1
        event = .level(sequence: sequence, rms: rms)
    }
}
