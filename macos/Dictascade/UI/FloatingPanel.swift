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
    private var guideWindowTop: NSWindow?
    private var guideWindowBottom: NSWindow?
    private var ghostWindow: NSWindow?
    private var shouldSnap = false
    private var isDragging = false
    @MainActor static var isMenuOpen = false

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
        setContentSize(size)

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
            let passthrough = Unmanaged.passRetained(event)

            switch keyCode {
            case 53: // Escape — let NSMenu handle it if a menu is open
                if FloatingPanel.isMenuOpen {
                    return passthrough
                }
                Task { @MainActor in
                    let state = AppState.shared
                    if state.isError {
                        state.dismissError()
                    } else if state.isTranscribing || state.isPostProcessing {
                        state.cancelTranscription()
                    } else if state.isPaused {
                        state.togglePause()
                    } else if state.isRecording {
                        state.togglePause()
                    }
                }
                return nil
            case 36: // Enter — only handle in error or paused state
                let state = AppState.shared
                if state.isError || state.isPaused {
                    Task { @MainActor in
                        if state.isError, state.hasFailedRecording {
                            state.saveFailedRecording()
                        } else if state.isError {
                            state.dismissError()
                        } else if state.isPaused {
                            state.discardRecording()
                        }
                    }
                    return nil
                }
                return passthrough
            default:
                if let modeIndex = numberKeyMap[keyCode] {
                    let state = AppState.shared
                    // Only swallow if mode pills are visible and index is valid
                    let modePillsVisible = state.modes.count > 1 && !state.isTranscribing && !state.isPostProcessing && !state.isError
                    if modePillsVisible && modeIndex < state.modes.count {
                        Task { @MainActor in
                            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                                state.selectMode(index: modeIndex)
                            }
                        }
                        return nil
                    }
                }
                return passthrough
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
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
            self.runLoopSource = nil
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private static let snapThreshold: CGFloat = 20

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            isDragging = true
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp {
            isDragging = false
            if shouldSnap, let screen = screen ?? NSScreen.main {
                let snappedX = screen.visibleFrame.midX - frame.width / 2
                setFrameOrigin(NSPoint(x: snappedX, y: frame.origin.y))
                savePosition()
            }
            hideSnapIndicators()
        }
    }

    @objc private func windowDidMove(_ notification: Notification) {
        guard isDragging, let screen = screen ?? NSScreen.main else { return }
        let screenMidX = screen.visibleFrame.midX
        let panelMidX = frame.midX

        if abs(panelMidX - screenMidX) < Self.snapThreshold {
            shouldSnap = true
            showGhost(on: screen)
        } else {
            shouldSnap = false
            hideSnapIndicators()
        }
    }

    private func showGuide(on screen: NSScreen, ghostRect: NSRect) {
        let screenFrame = screen.visibleFrame
        let x = screen.frame.midX - 0.5

        // Top segment: from ghost top to visible screen top
        let gap: CGFloat = 4
        let topRect = NSRect(x: x, y: ghostRect.maxY + gap, width: 1, height: screenFrame.maxY - ghostRect.maxY - gap)
        // Bottom segment: from visible screen bottom to ghost bottom
        let bottomRect = NSRect(x: x, y: screenFrame.minY, width: 1, height: ghostRect.minY - screenFrame.minY - gap)

        guideWindowTop = updateOrCreateGuideWindow(existing: guideWindowTop, rect: topRect)
        guideWindowBottom = updateOrCreateGuideWindow(existing: guideWindowBottom, rect: bottomRect)
    }

    private func updateOrCreateGuideWindow(existing: NSWindow?, rect: NSRect) -> NSWindow {
        if let existing {
            existing.setFrame(rect, display: true)
            existing.contentView?.frame = NSRect(origin: .zero, size: rect.size)
            existing.contentView?.needsDisplay = true
            existing.orderFront(nil)
            return existing
        }

        let window = NSWindow(
            contentRect: rect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces]

        let dashedView = DashedLineView(frame: NSRect(origin: .zero, size: rect.size))
        window.contentView = dashedView
        window.backgroundColor = .clear
        window.orderFront(nil)
        return window
    }

    private func showGhost(on screen: NSScreen) {
        // Pill height without mode pills row
        let size = NSSize(width: frame.width, height: min(frame.height, 63))
        let snappedX = screen.visibleFrame.midX - size.width / 2
        let ghostY = frame.origin.y + frame.height - size.height
        let ghostRect = NSRect(x: snappedX, y: ghostY, width: size.width, height: size.height)

        if let ghostWindow {
            ghostWindow.setFrame(ghostRect, display: true)
            ghostWindow.contentView?.frame = NSRect(origin: .zero, size: ghostRect.size)
            ghostWindow.contentView?.needsDisplay = true
            ghostWindow.orderFront(nil)
        } else {
            let window = NSWindow(
                contentRect: ghostRect,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .floating
            window.isOpaque = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces]

            let ghostView = GhostView(frame: NSRect(origin: .zero, size: ghostRect.size))
            window.contentView = ghostView
            window.backgroundColor = .clear
            window.orderFront(nil)
            ghostWindow = window
        }

        showGuide(on: screen, ghostRect: ghostWindow?.frame ?? ghostRect)
    }

    private func hideSnapIndicators() {
        guideWindowTop?.orderOut(nil)
        guideWindowTop = nil
        guideWindowBottom?.orderOut(nil)
        guideWindowBottom = nil
        ghostWindow?.orderOut(nil)
        ghostWindow = nil
        shouldSnap = false
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
        hideSnapIndicators()
        NotificationCenter.default.removeObserver(self)
    }
}

private class DashedLineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.move(to: CGPoint(x: 0.5, y: 0))
        context.addLine(to: CGPoint(x: 0.5, y: bounds.height))
        context.strokePath()
    }
}

private class GhostView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let cornerRadius = min(rect.height / 2, rect.width / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.4).cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [6, 4])
        context.addPath(path)
        context.strokePath()

        context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.05).cgColor)
        context.addPath(path)
        context.fillPath()
    }
}
