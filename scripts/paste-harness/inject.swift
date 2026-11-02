// Standalone text-injection harness. Usage:
//   inject <method> <expectedBundleID> <textFile> [restoreSeconds]
// methods: cmdv (production replica), cmdv:<ms> (custom wait after clipboard write),
//          chord (explicit Cmd down/up like a real keyboard), menu (AX Edit>Paste),
//          type (Unicode key events, no clipboard)
// Exit codes: 0 ok, 2 wrong frontmost app, 3 method failed.
import AppKit
import ApplicationServices
import Foundation

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 4 else { print("usage"); exit(64) }
let method = args[1]
let expected = args[2]
let text = try! String(contentsOfFile: args[3], encoding: .utf8)
let restoreSeconds = args.count > 4 ? Double(args[4])! : 3.0

func msleep(_ ms: Int) { usleep(useconds_t(ms * 1000)) }
func frontmost() -> NSRunningApplication? { NSWorkspace.shared.frontmostApplication }
func checkFront() {
    guard frontmost()?.bundleIdentifier == expected else {
        print("ABORT frontmost=\(frontmost()?.bundleIdentifier ?? "nil")"); exit(2)
    }
}
func modifiersHeld() -> Bool {
    !CGEventSource.flagsState(.hidSystemState)
        .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty
}

// --- Clipboard transaction (same semantics as PasteboardTransaction) ---
let pb = NSPasteboard.general
var saved: [[(NSPasteboard.PasteboardType, Data)]] = []
var writtenCount = -1
func writeClipboard() {
    saved = pb.pasteboardItems?.map { item in
        item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
    } ?? []
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
    pb.clearContents()
    pb.writeObjects([item])
    writtenCount = pb.changeCount
}
func restoreClipboard() {
    guard writtenCount >= 0 else { return }
    Thread.sleep(forTimeInterval: restoreSeconds)
    guard pb.changeCount == writtenCount, !saved.isEmpty else { print("restore skipped"); return }
    let items = saved.map { types -> NSPasteboardItem in
        let i = NSPasteboardItem(); for (t, d) in types { i.setData(d, forType: t) }; return i
    }
    pb.clearContents(); pb.writeObjects(items)
}

// --- Methods ---
func productionCmdV(waitAfterWrite: Int) {
    msleep(150)                     // production: settle after shortcut
    var waited = 0
    while modifiersHeld() { msleep(25); waited += 25; if waited > 2000 { print("MODS_STUCK"); exit(3) } }
    checkFront()
    writeClipboard()
    msleep(waitAfterWrite)          // production: 75 ms
    checkFront()
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)!
    let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)!
    down.flags = .maskCommand; up.flags = []
    down.post(tap: .cghidEventTap); msleep(20); up.post(tap: .cghidEventTap)
}

func chord() {
    msleep(150); checkFront(); writeClipboard(); msleep(75); checkFront()
    let src = CGEventSource(stateID: .hidSystemState)
    func key(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        e.flags = flags; e.post(tap: .cghidEventTap)
    }
    let cmd = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8) // + left-cmd device bit
    key(55, true, cmd); msleep(10)
    key(9, true, cmd); msleep(20)
    key(9, false, cmd); msleep(10)
    key(55, false, [])
}

func findPasteMenuItem(pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    guard let bar = attr(app, kAXMenuBarAttribute) else { return nil }
    let barEl = bar as! AXUIElement
    for top in (attr(barEl, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        for menu in (attr(top, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            for item in (attr(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                let ch = attr(item, kAXMenuItemCmdCharAttribute) as? String
                let mods = (attr(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue
                if ch?.uppercased() == "V", mods == 0 { return item }   // 0 == Command only
            }
        }
    }
    return nil
}

func menuPaste() {
    msleep(150); checkFront()
    let pid = frontmost()!.processIdentifier
    let t0 = Date()
    guard let item = findPasteMenuItem(pid: pid) else { print("NO_MENU_ITEM"); exit(3) }
    print(String(format: "menu lookup %.0f ms", Date().timeIntervalSince(t0) * 1000))
    writeClipboard(); msleep(75); checkFront()
    let r = AXUIElementPerformAction(item, kAXPressAction as CFString)
    print("AXPress result \(r.rawValue)")
    if r != .success { exit(3) }
}

func typeText() {
    msleep(150)
    var waited = 0
    while modifiersHeld() { msleep(25); waited += 25; if waited > 2000 { print("MODS_STUCK"); exit(3) } }
    checkFront()
    let src = CGEventSource(stateID: .hidSystemState)
    func post(_ units: [UniChar]) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
            e.flags = []
            units.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            e.post(tap: .cghidEventTap)
        }
    }
    func returnKey() {
        for down in [true, false] {
            // Shift+Return like the app: line break without submitting chat/form fields.
            let e = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down)!
            e.flags = down ? .maskShift : []; e.post(tap: .cghidEventTap)
        }
    }
    let t0 = Date()
    for (i, line) in text.components(separatedBy: "\n").enumerated() {
        if i > 0 { returnKey(); msleep(2) }
        var chunk: [UniChar] = []
        for scalarStr in line.map(String.init) {            // grapheme clusters never split
            let u = Array(scalarStr.utf16)
            if chunk.count + u.count > 20 { post(chunk); chunk = []; msleep(2); checkFront() }
            chunk += u
        }
        if !chunk.isEmpty { post(chunk) }
    }
    msleep(200)
    print(String(format: "typed in %.0f ms", Date().timeIntervalSince(t0) * 1000))
}

func postCmdV() {
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)!
    let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)!
    down.flags = .maskCommand; up.flags = []
    down.post(tap: .cghidEventTap); msleep(20); up.post(tap: .cghidEventTap)
}
// Diagnostic: is the SECOND paste of the same clipboard contents accepted?
func doublePaste() {
    msleep(150); checkFront(); writeClipboard(); msleep(75); checkFront()
    postCmdV(); msleep(400); checkFront(); postCmdV()
}
// Make the app read the pasteboard (menu validation) before pasting.
func primeViaMenu(_ wait: Int = 150) {
    msleep(150); checkFront()
    guard let item = findPasteMenuItem(pid: frontmost()!.processIdentifier) else { print("NO_MENU_ITEM"); exit(3) }
    writeClipboard()
    var v: AnyObject?
    AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &v)
    print("paste enabled \(String(describing: v))")
    msleep(wait); checkFront(); postCmdV()
}
switch method {
case "double": doublePaste()
case "prime": primeViaMenu()
case let m where m.hasPrefix("prime:"): primeViaMenu(Int(m.dropFirst(6))!)
case "cmdv": productionCmdV(waitAfterWrite: 75)
case let m where m.hasPrefix("cmdv:"): productionCmdV(waitAfterWrite: Int(m.dropFirst(5))!)
case "chord": chord()
case "menu": menuPaste()
case "type": typeText()
default: print("unknown method"); exit(64)
}
restoreClipboard()
print("done")
