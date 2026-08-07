import AVFoundation
import Foundation

/// Converts microphone buffers to the 16 kHz mono Float32 stream expected by
/// the transcription engines. The source format is allowed to change while a
/// recording is active (for example when a Bluetooth headset enters HFP mode).
final class AudioSampleConverter {
    private let lock = NSLock()
    private let targetFormat = AVAudioFormat(
        standardFormatWithSampleRate: 16_000,
        channels: 1
    )!

    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    func reset() {
        lock.lock()
        sourceFormat = nil
        converter = nil
        lock.unlock()
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }

        guard buffer.frameLength > 0 else { return [] }

        let format = buffer.format
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }

        if format.sampleRate == targetFormat.sampleRate,
           format.channelCount == targetFormat.channelCount,
           format.commonFormat == .pcmFormatFloat32,
           !format.isInterleaved,
           let channel = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }

        if sourceFormat != format {
            sourceFormat = format
            converter = AVAudioConverter(from: format, to: targetFormat)
        }

        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / format.sampleRate
        let expectedFrames = ceil(Double(buffer.frameLength) * ratio)
        let capacity = AVAudioFrameCount(max(1, expectedFrames + 32))
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            return nil
        }

        var conversionError: NSError?
        var suppliedInput = false
        converter.convert(to: convertedBuffer, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }

            suppliedInput = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              let channel = convertedBuffer.floatChannelData?[0] else {
            return nil
        }

        return Array(
            UnsafeBufferPointer(
                start: channel,
                count: Int(convertedBuffer.frameLength)
            )
        )
    }
}
