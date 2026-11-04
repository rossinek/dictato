import XCTest

final class SpeechCropperTests: XCTestCase {
    private let rate = SpeechCropper.sampleRate
    private func samples(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float($0) }
    }
    private func range(_ start: Double, _ end: Double) -> Range<Int> {
        Int(start * Double(rate))..<Int(end * Double(rate))
    }

    func testNoSpeechReturnsNil() {
        XCTAssertNil(SpeechCropper.crop(samples(5), speech: []))
    }

    func testTooLittleSpeechReturnsNil() {
        XCTAssertNil(SpeechCropper.crop(samples(5), speech: [range(1, 1.2)]))
    }

    func testCropsEdgesWithPadding() throws {
        let audio = samples(10)
        let cropped = try XCTUnwrap(SpeechCropper.crop(audio, speech: [range(3, 5)]))
        let padding = Int(SpeechCropper.edgePadding * Double(rate))
        XCTAssertEqual(cropped.count, 2 * rate + 2 * padding)
        XCTAssertEqual(cropped.first, audio[3 * rate - padding])
        XCTAssertEqual(cropped.last, audio[5 * rate + padding - 1])
    }

    func testPaddingIsClampedToRecording() throws {
        let audio = samples(2)
        let cropped = try XCTUnwrap(SpeechCropper.crop(audio, speech: [range(0.1, 1.9)]))
        XCTAssertEqual(cropped, audio)
    }

    func testShortensLongPausesAndKeepsShortOnes() throws {
        let audio = samples(20)
        let gap = Int(SpeechCropper.maxGap * Double(rate))
        let padding = Int(SpeechCropper.edgePadding * Double(rate))
        // 0.3 s pause is kept, 8 s pause is shortened to maxGap.
        let cropped = try XCTUnwrap(SpeechCropper.crop(audio, speech: [range(1, 2), range(2.3, 3), range(11, 12)]))
        let expected = padding + rate + Int(0.3 * Double(rate)) + Int(0.7 * Double(rate)) + gap + rate + padding
        XCTAssertEqual(cropped.count, expected)
        // Samples stay in order: the cropped audio is a subsequence of the original.
        XCTAssertEqual(cropped, cropped.sorted())
    }

    func testOverlappingRegionsAreNotDuplicated() throws {
        let audio = samples(10)
        let cropped = try XCTUnwrap(SpeechCropper.crop(audio, speech: [range(1, 3), range(2, 4)]))
        let padding = Int(SpeechCropper.edgePadding * Double(rate))
        XCTAssertEqual(cropped.count, 3 * rate + 2 * padding)
        XCTAssertEqual(Set(cropped).count, cropped.count)
    }
}
