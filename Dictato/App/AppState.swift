import Foundation
import SwiftUI

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isRecording = false
    @Published var transcriptionHistory: [Transcription] = []

    private init() {}
}
