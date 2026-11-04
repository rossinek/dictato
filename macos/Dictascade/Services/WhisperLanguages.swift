import Foundation
import WhisperKit

/// Languages offered in Settings (mode language and Whisper auto-detection).
enum TranscriptionLanguage {
    static let all: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("ru", "Russian"),
        ("hi", "Hindi"),
        ("pl", "Polish"),
        ("sv", "Swedish"),
        ("uk", "Ukrainian"),
        ("tr", "Turkish"),
    ]
}

/// Languages Whisper chooses from when a mode's language is Auto-detect
/// (Settings → Whisper gear). Short or quiet recordings otherwise come out in a
/// random language ("Так" for "Tak", "Не." for "Nie"). Empty means any language.
enum WhisperAutoDetectLanguages {
    static let defaultsKey = "whisperAutoDetectLanguages"
    static let defaultValue = ["pl", "en"]

    static var current: [String] {
        (UserDefaults.standard.array(forKey: defaultsKey) as? [String]) ?? defaultValue
    }
}

/// Reports only the allowed languages as language tokens. WhisperKit's language
/// detection masks every token outside `allLanguageTokens`, so it then picks the most
/// likely allowed language, from the same encoder pass as the transcription.
///
/// WhisperKit 0.17 builds that mask once per text decoder, on the first detection:
/// set the tokenizer right after loading and load a new instance to change the set.
final class LanguageRestrictedTokenizer: WhisperTokenizer {
    private let base: WhisperTokenizer
    let allLanguageTokens: Set<Int>

    /// Returns nil when none of the codes is a Whisper language token.
    init?(_ base: WhisperTokenizer, languages: [String]) {
        let tokens = Set(languages.compactMap { base.convertTokenToId("<|\($0)|>") })
            .intersection(base.allLanguageTokens)
        guard !tokens.isEmpty else { return nil }
        self.base = base
        allLanguageTokens = tokens
    }

    var specialTokens: SpecialTokens { base.specialTokens }
    func encode(text: String) -> [Int] { base.encode(text: text) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        base.splitToWordTokens(tokenIds: tokenIds)
    }
}
