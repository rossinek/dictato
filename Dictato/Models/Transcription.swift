import Foundation

struct Transcription: Identifiable, Codable {
    let id: UUID
    let text: String
    let date: Date
    let modeName: String?

    init(text: String, modeName: String? = nil) {
        self.id = UUID()
        self.text = text
        self.date = Date()
        self.modeName = modeName
    }
}
