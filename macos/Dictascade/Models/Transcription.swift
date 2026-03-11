import Foundation

struct Transcription: Identifiable, Codable {
    let id: UUID
    var text: String
    let date: Date
    var modeName: String?
    var postProcessedText: String?
    var audioFileName: String?

    enum CodingKeys: String, CodingKey {
        case id, text, date, modeName, postProcessedText, audioFileName
    }

    init(text: String, postProcessedText: String? = nil, modeName: String? = nil, audioFileName: String? = nil) {
        self.id = UUID()
        self.text = text
        self.date = Date()
        self.modeName = modeName
        self.postProcessedText = postProcessedText
        self.audioFileName = audioFileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        date = try container.decode(Date.self, forKey: .date)
        modeName = try container.decodeIfPresent(String.self, forKey: .modeName)
        postProcessedText = try container.decodeIfPresent(String.self, forKey: .postProcessedText)
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
    }
}
