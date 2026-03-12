import Foundation

struct TranscriptionMode: Identifiable, Codable {
    let id: UUID
    var name: String
    var language: String?  // nil = auto-detect
    var prompt: String
    var provider: LLMProvider
    var model: String?
    var transcriptionEngine: TranscriptionEngine

    static let `default` = TranscriptionMode(
        id: UUID(), name: "Default", language: nil, prompt: "",
        provider: .none, model: nil, transcriptionEngine: .fluidAudio
    )

    enum CodingKeys: String, CodingKey {
        case id, name, language, prompt, provider, model, transcriptionEngine
    }

    init(id: UUID, name: String, language: String?, prompt: String, provider: LLMProvider = .none, model: String? = nil, transcriptionEngine: TranscriptionEngine = .fluidAudio) {
        self.id = id
        self.name = name
        self.language = language
        self.prompt = prompt
        self.provider = provider
        self.model = model
        self.transcriptionEngine = transcriptionEngine
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        prompt = try container.decode(String.self, forKey: .prompt)
        provider = try container.decodeIfPresent(LLMProvider.self, forKey: .provider) ?? .none
        model = try container.decodeIfPresent(String.self, forKey: .model)
        transcriptionEngine = try container.decodeIfPresent(TranscriptionEngine.self, forKey: .transcriptionEngine) ?? .fluidAudio
    }
}
