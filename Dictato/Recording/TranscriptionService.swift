import Foundation

class TranscriptionService {
    func downloadModelIfNeeded() async {
        // TODO: Use WhisperKit to download large-v3-turbo on first launch
    }

    func transcribe(audioURL: URL) async throws -> String {
        // TODO: Run WhisperKit inference on audio file, return text
        return ""
    }
}
