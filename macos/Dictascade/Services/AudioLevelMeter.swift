import Combine
import Foundation

/// Microphone levels on a fixed audio-time grid, independent of how the capture
/// pipeline batches its buffers.
///
/// Samples (16 kHz mono) are reduced to one RMS value per 10 ms window. The
/// visualizer reads the history every frame through `level(from:to:)` and
/// `audioTime(at:)`; nothing here is published per buffer, so views observing
/// AppState are not invalidated for every incoming audio buffer.
@MainActor
final class AudioLevelMeter: ObservableObject {
    static let windowDuration: Double = 0.01
    private static let samplesPerWindow = 160 // 10 ms at 16 kHz
    private static let retainedWindows = 1000 // 10 s

    /// Number of resets; lets views clear per-recording state.
    @Published private(set) var generation = 0

    /// RMS per window; `levels[0]` is window number `firstWindow` of the recording.
    private var levels: [Float] = []
    private var firstWindow = 0
    private var partialSumOfSquares: Float = 0
    private var partialCount = 0
    /// Wall-clock time corresponding to audio time 0; the drawing clock.
    private var clockOrigin: Date?
    /// Since when data has been arriving later than the jitter tolerance.
    private var lateSince: Date?
    private static let jitterTolerance: Double = 0.05

    private var audioEnd: Double { Double(firstWindow + levels.count) * Self.windowDuration }

    func reset() {
        levels.removeAll(keepingCapacity: true)
        firstWindow = 0
        partialSumOfSquares = 0
        partialCount = 0
        clockOrigin = nil
        lateSince = nil
        generation &+= 1
    }

    func append(_ samples: [Float], at arrival: Date = .now) {
        for sample in samples {
            partialSumOfSquares += sample * sample
            partialCount += 1
            if partialCount == Self.samplesPerWindow {
                levels.append(sqrt(partialSumOfSquares / Float(partialCount)))
                partialSumOfSquares = 0
                partialCount = 0
            }
        }
        if levels.count > Self.retainedWindows {
            let excess = levels.count - Self.retainedWindows
            levels.removeFirst(excess)
            firstWindow += excess
        }
        anchorClock(arrival: arrival)
    }

    /// Audio time shown at `date`, `latency` behind the newest data in steady state.
    func audioTime(at date: Date, latency: Double) -> Double? {
        guard let clockOrigin else { return nil }
        return date.timeIntervalSince(clockOrigin) - latency
    }

    /// Mean RMS over an audio-time interval, weighting partially covered windows
    /// (linear interpolation of the window grid). Nil if the interval has no data yet.
    func level(from start: Double, to end: Double) -> Float? {
        guard end > start, start < audioEnd, end <= audioEnd + Self.windowDuration else { return nil }
        let window = Self.windowDuration
        var sum: Double = 0
        var weight: Double = 0
        var index = Int(floor(start / window))
        while Double(index) * window < end {
            let local = index - firstWindow
            if local >= 0, local < levels.count {
                let overlap = min(end, Double(index + 1) * window) - max(start, Double(index) * window)
                if overlap > 0 {
                    sum += Double(levels[local]) * overlap
                    weight += overlap
                }
            }
            index += 1
        }
        return weight > 0 ? Float(sum / weight) : nil
    }

    /// Keeps the drawing clock running smoothly on the newest data. Bluetooth headsets
    /// stall for a few hundred ms right after starting and then deliver the backlog in
    /// a burst. The clock ignores such stalls (bars without data are drawn as silence
    /// and fill in when the backlog arrives), so the bars never jump:
    /// - data ahead of the clock: catch up at once (only by the arrival jitter);
    /// - small lateness (jitter): follow gently;
    /// - larger lateness: wait for the backlog; only if it persists (a device switch
    ///   without backlog) is it adopted, gradually.
    private func anchorClock(arrival: Date) {
        let end = audioEnd
        guard end > 0 else { return }
        // The origin this arrival implies if audio were delivered without delay.
        let implied = arrival.addingTimeInterval(-end)
        guard let clockOrigin else {
            clockOrigin = implied
            return
        }
        let lateness = implied.timeIntervalSince(clockOrigin)
        if lateness < 0 {
            self.clockOrigin = implied
            lateSince = nil
        } else if lateness <= Self.jitterTolerance {
            self.clockOrigin = clockOrigin.addingTimeInterval(lateness * 0.02)
            lateSince = nil
        } else if let lateSince, arrival.timeIntervalSince(lateSince) > 1 {
            self.clockOrigin = clockOrigin.addingTimeInterval(lateness * 0.03)
        } else if lateSince == nil {
            lateSince = arrival
        }
    }
}
