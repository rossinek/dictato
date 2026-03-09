import AppKit
import SwiftUI

class FloatingPanel: NSPanel {
    private static let offsetXKey = "panelOffsetX"
    private static let offsetYKey = "panelOffsetY"
    private static let positionSavedKey = "panelPositionSaved"

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(contentView: some View) {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: contentView)
        self.contentView = hostingView
        let size = hostingView.fittingSize
        setContentSize(NSSize(width: max(360, size.width), height: size.height))

        restorePosition()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func installKeyMonitor() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // Number keys 1-9: keyCodes 18-21 (1-4), 23 (5), 22 (6), 26 (7), 28 (8), 25 (9)
            let numberKeyMap: [Int64: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]

            switch keyCode {
            case 53: // Escape
                Task { @MainActor in
                    let state = AppState.shared
                    if state.isTranscribing || state.isPostProcessing {
                        state.cancelTranscription()
                    } else {
                        state.togglePause()
                    }
                }
                return nil // swallow the event
            case 36: // Enter
                Task { @MainActor in
                    if AppState.shared.isPaused {
                        AppState.shared.discardRecording()
                    }
                }
                return nil
            default:
                if let modeIndex = numberKeyMap[keyCode] {
                    Task { @MainActor in
                        AppState.shared.selectMode(index: modeIndex)
                    }
                    return nil
                }
                return Unmanaged.passRetained(event)
            }
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil
        )

        if let eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            if let runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            }
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    func removeKeyMonitor() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
                self.runLoopSource = nil
            }
            self.eventTap = nil
        }
    }

    @objc private func windowDidMove(_ notification: Notification) {
        savePosition()
    }

    func savePosition() {
        guard let screen = screen ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        let panelMidX = frame.midX
        let panelMidY = frame.midY
        let screenMidX = screenFrame.midX
        let screenMidY = screenFrame.midY

        let offsetX = (panelMidX - screenMidX) / screenFrame.width
        let offsetY = (panelMidY - screenMidY) / screenFrame.height

        UserDefaults.standard.set(offsetX, forKey: Self.offsetXKey)
        UserDefaults.standard.set(offsetY, forKey: Self.offsetYKey)
        UserDefaults.standard.set(true, forKey: Self.positionSavedKey)
    }

    private func restorePosition() {
        guard UserDefaults.standard.bool(forKey: Self.positionSavedKey),
              let screen = NSScreen.main else {
            centerOnScreen()
            return
        }

        let screenFrame = screen.visibleFrame
        let offsetX = UserDefaults.standard.double(forKey: Self.offsetXKey)
        let offsetY = UserDefaults.standard.double(forKey: Self.offsetYKey)

        let x = screenFrame.midX + offsetX * screenFrame.width - frame.width / 2
        let y = screenFrame.midY + offsetY * screenFrame.height - frame.height / 2

        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.maxY - frame.height - 80
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    deinit {
        removeKeyMonitor()
    }
}
