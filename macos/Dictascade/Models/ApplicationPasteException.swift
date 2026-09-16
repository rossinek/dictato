import Foundation
import KeyboardShortcuts

struct ApplicationPasteException: Codable, Identifiable, Equatable {
    let bundleIdentifier: String
    var applicationName: String
    var applicationPath: String

    var id: String { bundleIdentifier }

    var shortcutName: KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("applicationPasteException.\(bundleIdentifier)")
    }
}

enum ApplicationPasteExceptionStore {
    private static let defaultsKey = "applicationPasteExceptions"

    static func load(from defaults: UserDefaults = .standard) -> [ApplicationPasteException] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([ApplicationPasteException].self, from: data)) ?? []
    }

    static func save(
        _ exceptions: [ApplicationPasteException],
        to defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(exceptions) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func exception(
        for bundleIdentifier: String,
        in defaults: UserDefaults = .standard
    ) -> ApplicationPasteException? {
        load(from: defaults).first { $0.bundleIdentifier == bundleIdentifier }
    }
}
