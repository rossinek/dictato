import SwiftUI

/// Ordered microphone priority list. Saved devices stay listed while disconnected;
/// Auto (the system default input) is always the last entry.
struct MicrophoneSettingsSection: View {
    @StateObject private var monitor = AudioInputDeviceMonitor()
    @State private var preferences = InputDevicePreferenceStore.load()

    private var deviceEntries: [InputDevicePreference] { preferences.filter { !$0.isAuto } }

    private var addableDevices: [AudioInputDevice] {
        let listed = Set(deviceEntries.compactMap(\.uid))
        return monitor.devices.filter { !listed.contains($0.uid) }
    }

    private var resolved: ResolvedAudioInput {
        InputDeviceResolver.resolve(
            preferences,
            available: monitor.devices,
            builtInMicrophoneUnavailable: AudioInputDevices.isClamshellClosed
        )
    }

    var body: some View {
        Section {
            ForEach(Array(deviceEntries.enumerated()), id: \.element.id) { index, entry in
                deviceRow(entry, index: index)
            }
            autoRow

            HStack {
                Text("Recording uses the first connected microphone in this list. Auto uses the input selected in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(addableDevices) { device in
                        Button(device.name) { add(device) }
                    }
                } label: {
                    Label("Add Microphone", systemImage: "plus")
                }
                .menuStyle(.button)
                .fixedSize()
                .controlSize(.small)
                .disabled(addableDevices.isEmpty)
            }
        } header: {
            Text("Microphone")
        }
    }

    // MARK: - Rows

    private func deviceRow(_ entry: InputDevicePreference, index: Int) -> some View {
        let device = entry.uid.flatMap { _ in
            InputDeviceResolver.match(entry, in: monitor.devices, preferences: preferences)
        }
        let isActive: Bool = {
            if case .device(let active, _) = resolved { return active.uid == device?.uid }
            return false
        }()

        return HStack(spacing: 10) {
            Text("\(index + 1).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Image(systemName: Self.symbol(for: entry.transport))
                .frame(width: 20)
                .foregroundStyle(device == nil ? .tertiary : .primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1)
                Text(status(for: device, isActive: isActive))
                    .font(.caption2)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            Spacer()
            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .help("Higher priority")
            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .disabled(index == deviceEntries.count - 1)
                .help("Lower priority")
            Button(role: .destructive) { remove(entry) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .help("Remove from list")
        }
        .padding(.vertical, 2)
    }

    private var autoRow: some View {
        let isActive = resolved == .systemDefault
        return HStack(spacing: 10) {
            Text("\(deviceEntries.count + 1).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Image(systemName: "wand.and.stars")
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto")
                Text(autoStatus(isActive: isActive))
                    .font(.caption2)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func status(for device: AudioInputDevice?, isActive: Bool) -> String {
        guard let device else { return "Not connected" }
        if device.transport == .builtIn && AudioInputDevices.isClamshellClosed {
            return "Unavailable while the lid is closed"
        }
        return isActive ? "Connected · used for recording" : "Connected"
    }

    private func autoStatus(isActive: Bool) -> String {
        let name = monitor.defaultDevice?.name ?? "none"
        return isActive ? "System default: \(name) · used for recording" : "System default: \(name)"
    }

    static func symbol(for transport: AudioInputTransport) -> String {
        switch transport {
        case .builtIn: "laptopcomputer"
        case .bluetooth: "headphones"
        case .usb: "cable.connector"
        case .virtual: "waveform"
        case .aggregate: "square.stack.3d.up"
        case .other: "mic"
        }
    }

    // MARK: - Editing

    private func add(_ device: AudioInputDevice) {
        update(deviceEntries + [InputDevicePreference(device: device)])
    }

    private func remove(_ entry: InputDevicePreference) {
        update(deviceEntries.filter { $0.id != entry.id })
    }

    private func move(_ index: Int, by offset: Int) {
        var entries = deviceEntries
        let target = index + offset
        guard entries.indices.contains(index), entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
        update(entries)
    }

    private func update(_ entries: [InputDevicePreference]) {
        preferences = InputDevicePreferenceStore.normalized(entries)
        InputDevicePreferenceStore.save(preferences)
    }
}
