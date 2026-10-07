// HoldSeek: tap Next/Previous to skip as usual, hold either one to seek.
// Works with Music, Spotify, and Chrome (through the companion extension in extension/).
import AppKit
import ServiceManagement
import os

let log = Logger(subsystem: "com.holdseek.HoldSeek", category: "main")  // log stream --predicate 'subsystem == "com.holdseek.HoldSeek"'

let hostName = "com.holdseek.bridge"
let extensionID = "kaabddkhedmmhfmhhnnjmoebaeopdded"  // derived from "key" in extension/manifest.json
let marker: Int64 = 0x484F4C44  // tags key events we re-post, so our own tap lets them through
// Keys are NX_KEYTYPE media codes (17 NEXT, 18 PREVIOUS, 19 FAST, 20 REWIND), plus plain F7/F9 for keyboards
// without media keys (or Macs set to "standard function keys"), stored as 1000 + their virtual key code.
let plainF7 = 1000 + 98, plainF9 = 1000 + 101
let nextKeys = [17, 19, plainF9]
let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("HoldSeek")

// MARK: - Hold logic

final class Hold {
    var delay = 0.4, tick = 0.2, step = 1.5  // tap/hold threshold, seek interval, seconds per jump (~8x)
    var repost: (Int) -> Void = { _ in }
    var pickTarget: () -> ((Double) -> Void)? = { nil }
    private var key: Int?, timer: Timer?, seeking = false

    func down(_ code: Int) {
        reset()
        key = code
        let jump = (nextKeys.contains(code) ? 1 : -1) * step
        timer = .scheduledTimer(withTimeInterval: delay, repeats: false) { [self] _ in
            guard let seek = pickTarget() else { return }  // nothing playing: release acts as a normal tap
            seeking = true  // the target stays fixed until release
            seek(jump)
            timer = .scheduledTimer(withTimeInterval: tick, repeats: true) { _ in seek(jump) }
        }
    }

    func up(_ code: Int) {
        guard code == key else { return }
        if !seeking { repost(code) }
        reset()
    }

    func reset() { timer?.invalidate(); timer = nil; key = nil; seeking = false }
}

// MARK: - Players

struct ScriptPlayer {
    let bundleID: String

    var isPlaying: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty  // never launch it
            && run("player state is playing")?.booleanValue == true
    }

    func seek(_ seconds: Double) { run("set player position to (player position) + \(seconds)") }

    @discardableResult func run(_ command: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let script = NSAppleScript(source: "with timeout of 1 second\ntell application id \"\(bundleID)\" to \(command)\nend timeout")
        let result = script?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}

let players = [ScriptPlayer(bundleID: "com.apple.Music"), ScriptPlayer(bundleID: "com.spotify.client")]
var chromePlaying = false, chromeConnected = false
var musicPlaying = false, spotifyPlaying = false  // from the apps' own notifications; read on the key thread
var anythingPlaying: Bool { musicPlaying || spotifyPlaying || chromePlaying }

func pickTarget() -> ((Double) -> Void)? {
    let player = players.first(where: \.isPlaying)
    log.notice("hold target: \(player?.bundleID ?? (chromePlaying ? "Chrome" : "none"), privacy: .public)")
    if let player { return player.seek }
    return chromePlaying ? { sendToChrome(["seek": $0]) } : nil
}

func sendToChrome(_ message: [String: Any]) {
    let json = String(decoding: try! JSONSerialization.data(withJSONObject: message), as: UTF8.self)
    DistributedNotificationCenter.default().postNotificationName(
        .init("\(hostName).command"), object: json, userInfo: nil, deliverImmediately: true)
}

// MARK: - Chrome bridge

// Chrome launches this same binary as its native messaging host. It relays between the extension
// (length-prefixed JSON on stdin/stdout) and the menu-bar app (distributed notifications).
func runBridge() -> Never {
    let center = DistributedNotificationCenter.default()
    let relay = { (json: String) in
        center.postNotificationName(.init("\(hostName).state"), object: json, userInfo: nil, deliverImmediately: true)
    }
    center.addObserver(forName: .init("\(hostName).command"), object: nil, queue: nil) { note in
        guard let body = (note.object as? String)?.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(withUnsafeBytes(of: UInt32(body.count)) { Data($0) } + body)
    }
    Thread {
        let stdin = FileHandle.standardInput
        while let header = try? stdin.read(upToCount: 4), header.count == 4,
              let body = try? stdin.read(upToCount: Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })) {
            relay(String(decoding: body, as: UTF8.self))
        }
        relay(#"{"playing":false,"connected":false}"#)  // Chrome closed the connection
        exit(0)
    }.start()
    RunLoop.main.run()
    exit(0)
}

func registerChromeHost() {
    let fm = FileManager.default
    let chrome = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome")
    guard fm.fileExists(atPath: chrome.path) else { return }
    // Chrome may not launch programs inside protected folders (Desktop, Downloads), so it gets its own copy.
    let bridge = supportDir.appendingPathComponent("HoldSeekBridge")
    try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try? fm.removeItem(at: bridge)
    guard let helper = Bundle.main.path(forAuxiliaryExecutable: "HoldSeekBridge") else { return }
    try? fm.copyItem(atPath: helper, toPath: bridge.path)
    // A downloaded app's files carry the quarantine flag, and so would this copy; macOS would then block Chrome
    // from launching it. The user already approved this app (it's running), so clear the flag on our own copy.
    removexattr(bridge.path, "com.apple.quarantine", 0)
    let hosts = chrome.appendingPathComponent("NativeMessagingHosts")
    try? fm.createDirectory(at: hosts, withIntermediateDirectories: true)
    let manifest: [String: Any] = [
        "name": hostName, "description": "HoldSeek", "type": "stdio", "path": bridge.path,
        "allowed_origins": ["chrome-extension://\(extensionID)/"],
    ]
    try? JSONSerialization.data(withJSONObject: manifest).write(to: hosts.appendingPathComponent("\(hostName).json"))
}

// MARK: - Key listener

var tap: CFMachPort?
var enabled = true
let hold = Hold()

func startTap() -> Bool {
    if tap != nil { return true }
    let keys: CGEventMask = 1 << 14 | 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue  // 14 = NX_SYSDEFINED
    tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                            eventsOfInterest: keys, callback: onEvent, userInfo: nil)
    guard let tap else { return false }
    log.notice("key listener running")
    Thread {  // its own thread, so a slow AppleScript on main never delays key events
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CFRunLoopRun()
    }.start()
    return true
}

func onEvent(_: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        CGEvent.tapEnable(tap: tap!, enable: true)
        plainHeld = nil
        DispatchQueue.main.async { hold.reset() }  // we may have missed a key release
        return pass
    }
    if type == .keyDown || type == .keyUp { return onPlainKey(type, event) }
    guard enabled, event.getIntegerValueField(.eventSourceUserData) != marker,
          let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return pass }
    let code = ns.data1 >> 16 & 0xFFFF, flags = ns.data1 & 0xFFFF, down = flags >> 8 == 0xA
    log.debug("media key \(code) \(down ? "down" : "up", privacy: .public)\(flags & 1 == 1 ? " (repeat)" : "", privacy: .public)")
    guard (17...20).contains(code) else { return pass }
    if flags & 1 == 0 {  // skip auto-repeats
        DispatchQueue.main.async { down ? hold.down(code) : hold.up(code) }
    }
    return nil  // swallow it; Hold re-posts it on release if it was a tap
}

var plainHeld: Int64?  // the F7/F9 press we took, so its repeats and release are taken too (key thread only)

// Plain F7/F9 are ordinary keys that apps use (F9 toggles breakpoints in many editors), so they're only taken
// bare and while something is playing. Every other key, and F7/F9 the rest of the time, passes straight through.
func onPlainKey(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event), key = event.getIntegerValueField(.keyboardEventKeycode)
    guard key == 98 || key == 101 else { return pass }
    if plainHeld == nil {
        let modified = !event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
        guard type == .keyDown, enabled, anythingPlaying, !modified,
              event.getIntegerValueField(.eventSourceUserData) != marker else { return pass }
        plainHeld = key
        log.debug("plain key \(key) down")
        DispatchQueue.main.async { hold.down(1000 + Int(key)) }
        return nil
    }
    guard key == plainHeld else { return pass }
    if type == .keyUp {
        plainHeld = nil
        DispatchQueue.main.async { hold.up(1000 + Int(key)) }
    }
    return nil  // the held key's auto-repeats and release
}

func repost(_ code: Int) {
    if code > 1000 {  // a plain F-key tap: give the app its key back
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code - 1000), keyDown: down)
            event?.setIntegerValueField(.eventSourceUserData, value: marker)
            event?.post(tap: .cghidEventTap)
        }
        return
    }
    for state in [0xA, 0xB] {  // key down, key up
        let flags = state << 8
        let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: .init(rawValue: UInt(flags)), timestamp: 0,
            windowNumber: 0, context: nil, subtype: 8, data1: code << 16 | flags, data2: -1)?.cgEvent
        event?.setIntegerValueField(.eventSourceUserData, value: marker)
        event?.post(tap: .cghidEventTap)
    }
}

// MARK: - Menu bar

// The app icon's keycap as a template image: hollow face, thicker bottom lip, fast-forward legend.
func menuBarIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2, width: 15, height: 14), xRadius: 4.2, yRadius: 4.2).fill()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSBezierPath(roundedRect: NSRect(x: 2.75, y: 4.5, width: 12.5, height: 10.25), xRadius: 3, yRadius: 3).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        let glyph = NSImage(systemSymbolName: "forward.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))!
        glyph.draw(in: NSRect(x: 9 - glyph.size.width / 2, y: 9.6 - glyph.size.height / 2,
                              width: glyph.size.width, height: glyph.size.height))
        return true
    }
    image.isTemplate = true  // macOS tints it for light and dark menu bars
    image.accessibilityDescription = "HoldSeek"
    return image
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    func applicationDidFinishLaunching(_: Notification) {
        let menu = NSMenu()
        for (title, action) in [("Enabled", #selector(toggleEnabled)), ("Launch at Login", #selector(toggleLogin)),
                                ("Grant Accessibility Access…", #selector(openAccessibility)),
                                ("Install Chrome Extension…", #selector(installExtension))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit HoldSeek", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.image = menuBarIcon()

        hold.repost = repost
        hold.pickTarget = pickTarget
        registerChromeHost()
        DistributedNotificationCenter.default().addObserver(forName: .init("\(hostName).state"), object: nil, queue: .main) {
            let state = ($0.object as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            chromePlaying = state?["playing"] as? Bool ?? false
            chromeConnected = state?["connected"] as? Bool ?? true
        }
        sendToChrome([:])  // ask an already-connected extension for its current state
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {  // sent on play, pause, track change
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(playerChanged), name: .init(name), object: nil, suspensionBehavior: .deliverImmediately)
        }

        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        if !startTap() {
            log.notice("key listener waiting for Accessibility access (trusted: \(AXIsProcessTrusted()), post: \(CGPreflightPostEventAccess()), listen: \(CGPreflightListenEventAccess()))")
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { if startTap() { $0.invalidate() } }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.items[0].state = enabled ? .on : .off
        menu.items[1].state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.items[2].isHidden = tap != nil
        menu.items[3].title = chromeConnected ? "Chrome Extension: Connected" : "Install Chrome Extension…"
    }

    @objc func playerChanged(_ note: Notification) {
        let playing = note.userInfo?["Player State"] as? String == "Playing"
        if note.name.rawValue.hasPrefix("com.apple.Music") { musicPlaying = playing } else { spotifyPlaying = playing }
    }

    @objc func toggleEnabled() {
        enabled.toggle()
        hold.reset()
        statusItem.button?.appearsDisabled = !enabled
    }

    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        else { try? SMAppService.mainApp.register() }
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func installExtension() {
        let fm = FileManager.default
        let dest = supportDir.appendingPathComponent("ChromeExtension")
        guard let source = Bundle.main.url(forResource: "ChromeExtension", withExtension: nil) else { return }
        try? fm.removeItem(at: dest)
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: source, to: dest)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dest.path, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([dest])

        let alert = NSAlert()
        alert.messageText = "Install the HoldSeek Chrome extension"
        alert.informativeText = """
            1. In Chrome, open chrome://extensions and turn on Developer mode.
            2. Click Load unpacked, press ⌘⇧G, paste (the folder path is on your clipboard), and click Select.
            3. Reload any tab that's already playing video.
            """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Self-check (run by build.sh)

// Waits for events rather than fixed times, so it passes on slow CI machines too.
func selfTest() -> Never {
    var reposted: [Int] = [], jumps: [Double] = [], playing = true, asked = false
    let h = Hold()
    h.delay = 0.05; h.tick = 0.02
    h.repost = { reposted.append($0) }
    h.pickTarget = { asked = true; return playing ? { jumps.append($0) } : nil }
    func wait(until done: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 10)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        precondition(done(), "timed out")
    }

    h.down(17); h.up(17)  // tap: released before the hold timer could run, so the original key goes through
    precondition(reposted == [17] && jumps.isEmpty, "tap should skip, not seek")
    h.down(20); wait { jumps.count >= 3 }; h.up(20)  // hold: seek backward, no skip
    precondition(reposted == [17] && jumps.allSatisfy { $0 < 0 }, "hold should seek backward")
    let count = jumps.count; RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    precondition(jumps.count == count, "seeking should stop on release")
    playing = false; asked = false
    h.down(19); wait { asked }; h.up(19)  // hold with nothing playing: falls back to a normal skip
    precondition(reposted == [17, 19], "hold without a player should skip")
    playing = true; jumps = []
    h.down(plainF9); wait { !jumps.isEmpty }; h.up(plainF9)  // plain F9, for keyboards without media keys
    precondition(jumps.allSatisfy { $0 > 0 }, "plain F9 should seek forward")

    // Plain F7/F9 are taken only bare and while something plays; every other key passes through.
    func key(_ code: CGKeyCode, down: Bool = true, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        return event
    }
    func taken(_ event: CGEvent) -> Bool { onPlainKey(event.type, event) == nil }
    chromePlaying = false
    precondition(!taken(key(101)), "F9 should pass through when nothing is playing")
    chromePlaying = true
    precondition(!taken(key(0)), "other keys should always pass through")
    precondition(!taken(key(101, flags: .maskCommand)), "⌘F9 should pass through")
    precondition(taken(key(101)) && taken(key(101)) && taken(key(101, down: false)), "bare F9, its repeat, and release should be taken")
    precondition(!taken(key(98, down: false)), "a release we didn't take should pass through")
    print("selftest passed")
    exit(0)
}

// MARK: - Entry

if CommandLine.arguments.dropFirst().first?.hasPrefix("chrome-extension://") == true { runBridge() }
if CommandLine.arguments.contains("--selftest") { selfTest() }
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
