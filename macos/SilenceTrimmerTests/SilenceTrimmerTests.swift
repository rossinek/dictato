import XCTest

final class SilenceTrimmerTests: XCTestCase {
    func testTrimsLeadingAndTrailingDigitalSilence() {
        let samples: [Float] = [0, 0, 1e-7, 0.01, -0.2, 0, 0.003, 0, 0]
        XCTAssertEqual(SilenceTrimmer.audibleRange(samples), 3..<7)
    }

    func testKeepsQuietSignalAboveThreshold() {
        // -80 dBFS: well below speech, but above digital silence.
        let samples: [Float] = [1e-4, 0, 1e-4]
        XCTAssertEqual(SilenceTrimmer.audibleRange(samples), 0..<3)
    }

    func testAllSilenceIsEmpty() {
        XCTAssertEqual(SilenceTrimmer.audibleRange([0, 0, 1e-6, -1e-6]), 0..<0)
        XCTAssertEqual(SilenceTrimmer.audibleRange([]), 0..<0)
    }
}
