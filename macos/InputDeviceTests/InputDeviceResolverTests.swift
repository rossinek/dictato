import XCTest

final class InputDeviceResolverTests: XCTestCase {
    private let airPods = AudioInputDevice(id: 10, uid: "EC-46-54-50-65-1B:input", name: "AirPods Pro", transport: .bluetooth)
    private let builtIn = AudioInputDevice(id: 11, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn)
    private let bose = AudioInputDevice(id: 12, uid: "4C-87-5D-00-00-01:input", name: "Bose 700 Headphones", transport: .bluetooth)

    private func pref(_ device: AudioInputDevice) -> InputDevicePreference { InputDevicePreference(device: device) }

    func testDefaultListIsOnlyAuto() {
        let defaults = UserDefaults(suiteName: "InputDeviceResolverTests-\(UUID())")!
        XCTAssertEqual(InputDevicePreferenceStore.load(from: defaults), [.auto])
        XCTAssertEqual(InputDeviceResolver.resolve([.auto], available: [builtIn, airPods]), .systemDefault)
    }

    func testAutoIsAlwaysExactlyOnceAndLast() {
        let normalized = InputDevicePreferenceStore.normalized([.auto, pref(airPods), .auto, pref(builtIn), pref(airPods)])
        XCTAssertEqual(normalized, [pref(airPods), pref(builtIn), .auto])
        XCTAssertEqual(InputDevicePreferenceStore.normalized([]), [.auto])
    }

    func testSaveAndLoadKeepDisconnectedDevicesAndOrder() {
        let defaults = UserDefaults(suiteName: "InputDeviceResolverTests-\(UUID())")!
        InputDevicePreferenceStore.save([.auto, pref(bose), pref(builtIn)], to: defaults)
        XCTAssertEqual(InputDevicePreferenceStore.load(from: defaults), [pref(bose), pref(builtIn), .auto])
    }

    func testFirstConnectedDeviceWins() {
        let list = [pref(airPods), pref(builtIn), .auto]
        XCTAssertEqual(InputDeviceResolver.resolve(list, available: [builtIn, airPods]), .device(airPods, priority: 1))
        XCTAssertEqual(InputDeviceResolver.resolve(list, available: [builtIn]), .device(builtIn, priority: 2))
    }

    func testFallsBackToAutoWhenNoListedDeviceIsConnected() {
        XCTAssertEqual(InputDeviceResolver.resolve([pref(bose), .auto], available: [builtIn, airPods]), .systemDefault)
    }

    func testDeadDeviceIsSkipped() {
        var deadAirPods = airPods
        deadAirPods.isAlive = false
        XCTAssertEqual(
            InputDeviceResolver.resolve([pref(airPods), pref(builtIn), .auto], available: [deadAirPods, builtIn]),
            .device(builtIn, priority: 2)
        )
    }

    func testBuiltInMicrophoneIsSkippedWhileLidIsClosed() {
        XCTAssertEqual(
            InputDeviceResolver.resolve([pref(builtIn), .auto], available: [builtIn], builtInMicrophoneUnavailable: true),
            .systemDefault
        )
    }

    func testUSBDeviceOnAnotherPortMatchesByNameAndTransport() {
        let saved = InputDevicePreference(uid: "AppleUSBAudioEngine:Acme:Mic:14100000:1", name: "Acme Mic", transport: .usb)
        let moved = AudioInputDevice(id: 20, uid: "AppleUSBAudioEngine:Acme:Mic:14200000:1", name: "Acme Mic", transport: .usb)
        XCTAssertEqual(InputDeviceResolver.resolve([saved, .auto], available: [moved]), .device(moved, priority: 1))
    }

    func testNameFallbackIsSkippedWhenAmbiguousOrClaimed() {
        let saved = InputDevicePreference(uid: "usb-old", name: "Acme Mic", transport: .usb)
        let first = AudioInputDevice(id: 20, uid: "usb-a", name: "Acme Mic", transport: .usb)
        let second = AudioInputDevice(id: 21, uid: "usb-b", name: "Acme Mic", transport: .usb)
        XCTAssertEqual(InputDeviceResolver.resolve([saved, .auto], available: [first, second]), .systemDefault)

        // "usb-a" has its own entry lower in the list, so it must not satisfy "usb-old".
        let list = [saved, InputDevicePreference(device: first), .auto]
        XCTAssertEqual(InputDeviceResolver.resolve(list, available: [first]), .device(first, priority: 2))
    }
}
