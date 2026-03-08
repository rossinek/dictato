import Foundation

struct TranscriptionMode: Identifiable, Codable {
    let id: UUID
    var name: String
    var language: String?  // nil = auto-detect
    var prompt: String     // empty by default, for future use

    static let `default` = TranscriptionMode(id: UUID(), name: "Default", language: nil, prompt: "")
}
