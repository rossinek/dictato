import XCTest

final class ChromiumEngineDetectorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromiumEngineDetectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeApp(_ name: String, framework: String, versions: [String]) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        for version in versions {
            let dir = app.appendingPathComponent("Contents/Frameworks/\(framework).framework/Versions/\(version)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return app
    }

    func testAffectedChromiumVersionsAreDetected() throws {
        let helium = try makeApp("Helium", framework: "Helium Framework", versions: ["156.0.8078.73", "Current"])
        XCTAssertEqual(ChromiumEngineDetector.affectedChromiumVersion(inApplicationAt: helium), "156.0.8078.73")
        let chrome155 = try makeApp("Chrome155", framework: "Google Chrome Framework", versions: ["155.0.8059.82"])
        XCTAssertEqual(ChromiumEngineDetector.affectedChromiumVersion(inApplicationAt: chrome155), "155.0.8059.82")
    }

    func testFixedAndOlderVersionsAreNotAffected() throws {
        for version in ["154.0.8000.1", "157.0.8100.2"] {
            let app = try makeApp("Browser-\(version)", framework: "Browser Framework", versions: [version, "Current"])
            XCTAssertNil(ChromiumEngineDetector.affectedChromiumVersion(inApplicationAt: app), version)
        }
    }

    func testStagedUpdateNextToAffectedVersionStillCounts() throws {
        let app = try makeApp("Staged", framework: "Browser Framework", versions: ["157.0.8100.2", "156.0.8078.73"])
        XCTAssertEqual(ChromiumEngineDetector.affectedChromiumVersion(inApplicationAt: app), "156.0.8078.73")
    }

    func testNewestAffectedVersionIsReported() throws {
        let app = try makeApp("Chrome", framework: "Google Chrome Framework", versions: ["156.0.8078.48", "156.0.8078.74", "156.0.8078.9"])
        XCTAssertEqual(ChromiumEngineDetector.affectedChromiumVersion(inApplicationAt: app), "156.0.8078.74")
    }

    func testElectronAndNativeAppsAreNotMatched() throws {
        let electron = try makeApp("Electron", framework: "Electron Framework", versions: ["A", "Current"])
        XCTAssertNil(ChromiumEngineDetector.affectedChromiumVersion(inApplicationAt: electron))
        let native = root.appendingPathComponent("Native.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        XCTAssertNil(ChromiumEngineDetector.affectedChromiumVersion(inApplicationAt: root.appendingPathComponent("Native.app")))
    }

    func testVersionDirectoryParsing() {
        XCTAssertEqual(ChromiumEngineDetector.chromiumMajorVersion(fromVersionDirectoryName: "156.0.8078.73"), 156)
        for name in ["A", "Current", "156.0.8078", "156.0.8078.73.1", "156..8078.73", "x156.0.1.2", "١٥٦.0.1.2"] {
            XCTAssertNil(ChromiumEngineDetector.chromiumMajorVersion(fromVersionDirectoryName: name), name)
        }
    }
}
