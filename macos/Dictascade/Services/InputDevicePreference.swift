import CoreAudio
import Foundation

enum AudioInputTransport: String, Codable, Equatable {
    case builtIn, bluetooth, usb, virtual, aggregate, other
}

/// An audio input device currently present in the system.
struct AudioInputDevice: Equatable, Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: AudioInputTransport
    var isAlive = true
}

/// One entry of the user's microphone priority list. `uid == nil` is "Auto"
/// (the system default input), which is always present and always last.
struct InputDevicePreference: Codable, Equatable, Identifiable {
    let uid: String?
    var name: String
    var transport: AudioInputTransport

    static let auto = InputDevicePreference(uid: nil, name: "Auto", transport: .other)

    var isAuto: Bool { uid == nil }
    var id: String { uid ?? "auto" }

    init(uid: String?, name: String, transport: AudioInputTransport) {
        self.uid = uid
        self.name = name
        self.transport = transport
    }

    init(device: AudioInputDevice) {
        self.init(uid: device.uid, name: device.name, transport: device.transport)
    }
}

enum InputDevicePreferenceStore {
    private static let defaultsKey = "inputDevicePreferences"

    static func load(from defaults: UserDefaults = .standard) -> [InputDevicePreference] {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([InputDevicePreference].self, from: data) else {
            return [.auto]
        }
        return normalized(saved)
    }

    static func save(_ preferences: [InputDevicePreference], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(normalized(preferences)) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Keeps each device once, in order, followed by exactly one Auto entry.
    static func normalized(_ preferences: [InputDevicePreference]) -> [InputDevicePreference] {
        var seen = Set<String>()
        let devices = preferences.filter { preference in
            guard let uid = preference.uid else { return false }
            return seen.insert(uid).inserted
        }
        return devices + [.auto]
    }
}

enum ResolvedAudioInput: Equatable {
    /// Record from this device; `priority` is its 1-based position in the list.
    case device(AudioInputDevice, priority: Int)
    /// Follow the system default input ("Auto").
    case systemDefault
}

enum InputDeviceResolver {
    /// Returns the first entry of the priority list that is usable right now.
    /// Auto always matches, so the walk always ends at the latest on Auto.
    static func resolve(
        _ preferences: [InputDevicePreference],
        available: [AudioInputDevice],
        builtInMicrophoneUnavailable: Bool = false
    ) -> ResolvedAudioInput {
        let preferences = InputDevicePreferenceStore.normalized(preferences)
        for (index, preference) in preferences.enumerated() {
            if preference.isAuto { return .systemDefault }
            guard let device = match(preference, in: available, preferences: preferences),
                  device.isAlive,
                  !(device.transport == .builtIn && builtInMicrophoneUnavailable) else {
                continue
            }
            return .device(device, priority: index + 1)
        }
        return .systemDefault
    }

    /// Matches by UID. A USB device without a serial number can get a different
    /// UID on another port, so fall back to name + transport when exactly one
    /// present device matches and it is not claimed by another list entry.
    static func match(
        _ preference: InputDevicePreference,
        in available: [AudioInputDevice],
        preferences: [InputDevicePreference]
    ) -> AudioInputDevice? {
        guard let uid = preference.uid else { return nil }
        if let exact = available.first(where: { $0.uid == uid }) { return exact }

        let claimed = Set(preferences.compactMap(\.uid))
        let candidates = available.filter {
            $0.name == preference.name && $0.transport == preference.transport && !claimed.contains($0.uid)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
