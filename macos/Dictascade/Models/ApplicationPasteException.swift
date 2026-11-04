import Foundation
import KeyboardShortcuts

/// How transcribed text is inserted into an application.
enum TextInsertionMethod: String, Codable, CaseIterable, Identifiable {
    /// Paste, except type into engines known to drop automatic pastes (Chromium 155–156).
    case automatic
    case paste
    case type
    /// Types physical keys of the current layout, for apps that ignore the Unicode
    /// text of key events and insert "a" for every Unicode event.
    case typeKeys

    var id: String { rawValue }

    var isTyping: Bool { self == .type || self == .typeKeys }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .paste: "Paste"
        case .type: "Type"
        case .typeKeys: "Type Keys"
        }
    }
}

struct ApplicationPasteException: Codable, Identifiable, Equatable {
    let bundleIdentifier: String
    var applicationName: String
    var applicationPath: String
    var insertionMethod: TextInsertionMethod = .automatic

    var id: String { bundleIdentifier }

    init(
        bundleIdentifier: String,
        applicationName: String,
        applicationPath: String,
        insertionMethod: TextInsertionMethod = .automatic
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.applicationPath = applicationPath
        self.insertionMethod = insertionMethod
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        applicationName = try container.decode(String.self, forKey: .applicationName)
        applicationPath = try container.decode(String.self, forKey: .applicationPath)
        // Exceptions saved before v1.5.2 have no insertion method.
        insertionMethod = (try? container.decodeIfPresent(TextInsertionMethod.self, forKey: .insertionMethod)) ?? .automatic
    }

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
