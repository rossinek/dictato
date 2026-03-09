import Foundation
import os

private let log = Logger(subsystem: "com.dictato.app", category: "LLMService")

enum LLMProvider: String, Codable, CaseIterable {
    case none
    case openai
    case groq

    var displayName: String {
        switch self {
        case .none: "No post-processing"
        case .openai: "OpenAI"
        case .groq: "Groq"
        }
    }

    var baseURL: URL? {
        switch self {
        case .none: nil
        case .openai: URL(string: "https://api.openai.com/v1")
        case .groq: URL(string: "https://api.groq.com/openai/v1")
        }
    }

    func apiKey() -> String? {
        switch self {
        case .none: nil
        case .openai: UserDefaults.standard.string(forKey: "openai_api_key")
        case .groq: UserDefaults.standard.string(forKey: "groq_api_key")
        }
    }
}

enum LLMError: LocalizedError {
    case noAPIKey
    case noBaseURL
    case apiError(statusCode: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey: "No API key configured"
        case .noBaseURL: "Invalid provider"
        case .apiError(let code, let message): "API error (\(code)): \(message)"
        case .invalidResponse: "Invalid response from API"
        }
    }
}

enum LLMService {
    private struct ModelsResponse: Decodable {
        let data: [ModelEntry]
    }

    private struct ModelEntry: Decodable {
        let id: String
        let created: Int?
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
    }

    private struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    private struct ChatResponse: Decodable {
        let choices: [ChatChoice]
    }

    private struct ChatChoice: Decodable {
        let message: ChatMessage
    }

    private struct APIErrorResponse: Decodable {
        let error: APIErrorDetail?
    }

    private struct APIErrorDetail: Decodable {
        let message: String?
    }

    static func fetchModels(provider: LLMProvider) async throws -> [String] {
        guard let baseURL = provider.baseURL else { throw LLMError.noBaseURL }
        guard let apiKey = provider.apiKey(), !apiKey.isEmpty else { throw LLMError.noAPIKey }

        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error?.message ?? "Unknown error"
            throw LLMError.apiError(statusCode: httpResponse.statusCode, message: message)
        }

        let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
        var entries = modelsResponse.data

        if provider == .openai {
            let excluded = ["image", "audio", "realtime", "codex", "tts", "whisper", "transcribe", "search", "research", "embedding", "dall-e", "davinci", "babbage", "sora"]
            entries = entries.filter { entry in
                let id = entry.id.lowercased()
                return !excluded.contains { id.contains($0) }
            }
        }

        let ids = entries
            .sorted { ($0.created ?? 0) > ($1.created ?? 0) }
            .map(\.id)
        log.info("Fetched \(ids.count) models from \(provider.displayName)")
        return ids
    }

    static func postProcess(provider: LLMProvider, model: String, systemPrompt: String, userMessage: String) async throws -> String {
        guard let baseURL = provider.baseURL else { throw LLMError.noBaseURL }
        guard let apiKey = provider.apiKey(), !apiKey.isEmpty else { throw LLMError.noAPIKey }

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userMessage),
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error?.message ?? "Unknown error"
            throw LLMError.apiError(statusCode: httpResponse.statusCode, message: message)
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let text = chatResponse.choices.first?.message.content else {
            throw LLMError.invalidResponse
        }

        log.info("Post-processing complete via \(provider.displayName)/\(model)")
        return text
    }
}
