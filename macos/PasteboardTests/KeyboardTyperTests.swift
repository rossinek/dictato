import XCTest

final class KeyboardTyperTests: XCTestCase {
    private func joinedText(_ chunks: [KeyboardTyper.Chunk]) -> String {
        chunks.map { chunk -> String in
            switch chunk {
            case .text(let units): String(utf16CodeUnits: units, count: units.count)
            case .lineBreak: "\n"
            }
        }.joined()
    }

    func testChunksRespectEventLimitAndRoundTrip() {
        let text = String(repeating: "Zażółć gęślą jaźń. ", count: 40)
        let chunks = KeyboardTyper.chunks(for: text)
        XCTAssertEqual(joinedText(chunks), text)
        for case .text(let units) in chunks {
            XCTAssertLessThanOrEqual(units.count, KeyboardTyper.maxUTF16UnitsPerEvent)
        }
    }

    func testGraphemeClustersAreNeverSplit() {
        // Each family emoji is 11 UTF-16 units; two do not fit in one 20-unit event.
        let family = "👨‍👩‍👧‍👦"
        let text = "ab" + family + family + "e\u{301}" + "🇵🇱"
        let chunks = KeyboardTyper.chunks(for: text)
        XCTAssertEqual(joinedText(chunks), text)
        for case .text(let units) in chunks {
            let string = String(utf16CodeUnits: units, count: units.count)
            XCTAssertEqual(Array(string.utf16), units, "Chunk must be valid UTF-16 on its own")
            XCTAssertFalse(string.unicodeScalars.first.map { (0xDC00...0xDFFF).contains($0.value) } ?? false)
        }
        // "ab" + family (13 units), then family + é + flag (17 units).
        XCTAssertEqual(chunks.count, 2)
    }

    func testOversizedClusterIsSentWhole() {
        let zalgo = "a" + String(repeating: "\u{301}", count: 30)
        XCTAssertEqual(KeyboardTyper.chunks(for: zalgo), [.text(Array(zalgo.utf16))])
    }

    func testLineBreaksBecomeSeparateEvents() {
        let chunks = KeyboardTyper.chunks(for: "Cześć,\n\nplan:\r\n- punkt")
        XCTAssertEqual(chunks, [
            .text(Array("Cześć,".utf16)), .lineBreak, .lineBreak,
            .text(Array("plan:".utf16)), .lineBreak, .text(Array("- punkt".utf16)),
        ])
    }

    func testEmptyTextProducesNoEvents() {
        XCTAssertEqual(KeyboardTyper.chunks(for: ""), [])
    }
}
