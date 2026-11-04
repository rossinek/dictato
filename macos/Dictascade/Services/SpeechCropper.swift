/// Keeps only the audio Whisper should hear, based on voice activity detection.
///
/// Whisper hallucinates on audio without speech ("Thank you.", "Thank God…", subtitle
/// credits) and detects the wrong language when a recording starts with seconds of
/// room noise. Cropping to the detected speech, with a margin, removes both; long
/// pauses are shortened so they cannot produce text either.
enum SpeechCropper {
    static let sampleRate = 16_000
    /// Margin kept before the first and after the last speech region. 0.25 s cut
    /// into the first word of a real recording ("Jeszcze" became "I jeszcze").
    static let edgePadding = 0.4
    /// Pauses between speech regions longer than this are shortened to it.
    static let maxGap = 0.6
    /// Less detected speech than this counts as no speech.
    static let minSpeech = 0.3

    /// - Parameters:
    ///   - samples: 16 kHz mono audio.
    ///   - speech: speech regions (sample ranges) in ascending order.
    /// - Returns: the cropped audio, or nil when there is no speech.
    static func crop(_ samples: [Float], speech: [Range<Int>]) -> [Float]? {
        let regions = speech
            .map { $0.clamped(to: 0..<samples.count) }
            .filter { !$0.isEmpty }
        let speechSamples = regions.reduce(0) { $0 + $1.count }
        guard let first = regions.first, let last = regions.last,
              Double(speechSamples) >= minSpeech * Double(sampleRate) else { return nil }

        let padding = Int(edgePadding * Double(sampleRate))
        let gap = Int(maxGap * Double(sampleRate))
        var output: [Float] = []
        output.reserveCapacity(samples.count)
        output.append(contentsOf: samples[max(0, first.lowerBound - padding)..<first.lowerBound])
        var end = first.lowerBound
        for region in regions {
            let start = max(region.lowerBound, end)
            if start - end > gap {
                // Keep half the allowed pause after the previous region and half before this one.
                output.append(contentsOf: samples[end..<(end + gap / 2)])
                output.append(contentsOf: samples[(start - gap / 2)..<start])
            } else {
                output.append(contentsOf: samples[end..<start])
            }
            let regionEnd = max(start, region.upperBound)
            output.append(contentsOf: samples[start..<regionEnd])
            end = regionEnd
        }
        output.append(contentsOf: samples[end..<min(samples.count, last.upperBound + padding)])
        return output
    }
}
