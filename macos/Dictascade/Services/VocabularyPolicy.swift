import FluidAudio

/// Keep vocabulary corrections anchored to similar transcript words or explicit aliases.
/// FluidAudio's acoustic-only rescue (enabled since 0.14.x) bypasses this similarity
/// gate and can replace unrelated words, especially with a short vocabulary.
enum VocabularyPolicy {
    static let minSimilarity: Float = 0.85
    static let rescoringConfig = VocabularyRescorer.Config(spotterRescueEnabled: false)
}
