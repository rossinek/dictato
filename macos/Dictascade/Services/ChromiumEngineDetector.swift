import Foundation

/// Detects applications embedding a Chromium engine whose macOS paste handling drops
/// synthetic pastes.
///
/// Chromium 155–156 cancel the default insertion of the first paste after another
/// application writes the pasteboard: the page receives a `paste` event with the
/// correct text, but nothing is inserted (regression from Chromium CL 8217390, fixed
/// by CL 8503629 in Chromium 157). Details and measurements: docs/automatic-paste.md.
enum ChromiumEngineDetector {
    static let affectedMajorVersions: ClosedRange<Int> = 155...156

    /// Returns the affected Chromium version embedded in the application, if any.
    ///
    /// Chromium-based browsers ship their engine as
    /// `Contents/Frameworks/<Name> Framework.framework/Versions/<a.b.c.d>/`. Every
    /// version folder counts, so an update staged next to the running version is
    /// still treated as affected. Electron apps (`Versions/A`) are not matched.
    static func affectedChromiumVersion(
        inApplicationAt applicationURL: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let frameworksURL = applicationURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let frameworks = try? fileManager.contentsOfDirectory(atPath: frameworksURL.path) else {
            return nil
        }

        var affected: [String] = []
        for framework in frameworks where framework.hasSuffix(".framework") {
            let versionsURL = frameworksURL
                .appendingPathComponent(framework, isDirectory: true)
                .appendingPathComponent("Versions", isDirectory: true)
            guard let versions = try? fileManager.contentsOfDirectory(atPath: versionsURL.path) else {
                continue
            }
            affected += versions.filter { version in
                chromiumMajorVersion(fromVersionDirectoryName: version).map(affectedMajorVersions.contains) ?? false
            }
        }
        // Report the newest affected version (browsers keep the previous one until relaunch).
        return affected.max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Parses a Chromium version folder name such as `156.0.8078.73`.
    static func chromiumMajorVersion(fromVersionDirectoryName name: String) -> Int? {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return Int(components[0])
    }
}
