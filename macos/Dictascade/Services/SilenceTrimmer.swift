import Foundation

/// Removes digital silence from the edges of a recording.
///
/// Bluetooth headsets deliver ~1.5–2.3 s of near-zero samples while switching to the
/// headset profile. Whisper, given that lead-in before a short utterance, becomes
/// unsure of the first token and re-decodes the whole window up to five times
/// (temperature fallback), which turned ~2 s transcriptions into 4–6 s.
/// The threshold sits far below any microphone noise floor (~-60 dBFS), so only
/// digital silence is removed, never quiet speech.
enum SilenceTrimmer {
    /// -100 dBFS.
    static let threshold: Float = 1e-5

    /// Returns the range of `samples` between the first and last sample above the
    /// threshold, or an empty range if the whole buffer is digital silence.
    static func audibleRange(_ samples: [Float], threshold: Float = threshold) -> Range<Int> {
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold }) else {
            return 0..<0
        }
        return first..<(last + 1)
    }
}
