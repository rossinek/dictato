import AVFoundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?

    func startRecording() {
        // TODO: Set up AVAudioEngine, tap mic input, write to buffer/file
    }

    func stopRecording() -> URL? {
        // TODO: Stop engine, return URL to recorded audio file
        return nil
    }
}
