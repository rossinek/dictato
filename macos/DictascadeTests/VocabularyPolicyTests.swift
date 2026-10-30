import FluidAudio
import XCTest

final class VocabularyPolicyTests: XCTestCase {
    /// Uses the already-installed CTC model; never downloads models during tests.
    func testUnrelatedPolishAndEnglishWordsCannotBecomeVocabularyTerms() async throws {
        let (spotter, directory, context) = try await fixtures()
        let safe = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: context,
            config: VocabularyPolicy.rescoringConfig, ctcModelDirectory: directory)
        let upstreamDefault = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: context, ctcModelDirectory: directory)

        for word in ["zrobimy", "jutro", "spotkanie", "ordinary", "meeting", "tomorrow"] {
            let timings = [TokenTiming(token: "▁" + word, tokenId: 1, startTime: 0, endTime: 0.5, confidence: 1)]
            // Demonstrate the regression: the new default admits unrelated words.
            XCTAssertTrue(upstreamDefault.hasCTCRescoringCandidates(
                transcript: word, tokenTimings: timings, minSimilarity: VocabularyPolicy.minSimilarity))
            XCTAssertFalse(safe.hasCTCRescoringCandidates(
                transcript: word, tokenTimings: timings, minSimilarity: VocabularyPolicy.minSimilarity), word)
        }
    }

    func testSimilarWordsAndExplicitAliasesStillQualifyForAcousticVerification() async throws {
        let (spotter, directory, context) = try await fixtures()
        let safe = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: context,
            config: VocabularyPolicy.rescoringConfig, ctcModelDirectory: directory)
        for word in ["Kubernetez", "kuber"] {
            let timings = [TokenTiming(token: "▁" + word, tokenId: 1, startTime: 0, endTime: 0.5, confidence: 1)]
            XCTAssertTrue(safe.hasCTCRescoringCandidates(
                transcript: word, tokenTimings: timings, minSimilarity: VocabularyPolicy.minSimilarity), word)
        }
    }

    private func fixtures() async throws -> (CtcKeywordSpotter, URL, CustomVocabularyContext) {
        let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        guard CtcModels.modelsExist(at: directory) else {
            throw XCTSkip("Requires the CTC 110M model already downloaded by vocabulary settings")
        }
        let models = try await CtcModels.loadDirect(from: directory)
        let tokenizer = try await CtcTokenizer.load(from: directory)
        let context = CustomVocabularyContext(terms: [
            CustomVocabularyTerm(text: "Kubernetes", aliases: ["kuber"], ctcTokenIds: tokenizer.encode("Kubernetes"))
        ])
        return (CtcKeywordSpotter(models: models), directory, context)
    }
}
