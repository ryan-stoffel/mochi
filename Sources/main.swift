// Mochi: a pixel critter that lives on your desktop and keeps you company.
// The window is a transparent, always-on-top panel hosting web/index.html. This file does the Mac parts:
// sensors (idle timers, sleep/wake, which app you're in, calls, battery), the window and how it gets around
// your screens (walking, hopping between windows, falling, being thrown), the panel's actions, and saving state.
import AppKit
import CoreAudio
import CoreMediaIO
import IOKit.ps
import ServiceManagement
import WebKit

// MARK: - Sensors

private let anyInput = CGEventType(rawValue: ~0)!

/// Seconds since the last input of this kind, system-wide. Needs no permissions and never sees what was typed.
private func idle(_ type: CGEventType) -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
}

private func bootTime() -> Double {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
}

private func json(_ obj: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return "null" }
    return s
}

/// Whether any camera is on (you're probably on a call). Reads a flag on the device, never the video.
private func cameraInUse() -> Bool {
    let system = CMIOObjectID(kCMIOObjectSystemObject)
    var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0, size > 0 else { return false }
    var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == 0 else { return false }
    return ids.contains { id in
        var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        var on: UInt32 = 0, got: UInt32 = 0
        return CMIOObjectGetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &on) == 0 && on != 0
    }
}

/// Whether the default mic (or speakers) are in use by any app. Again just a flag, never the audio.
private func audioInUse(input: Bool) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return false }
    addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
    var on: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &on) == noErr && on != 0
}

/// Battery charge 0...1 and whether it's plugged in; nil on a Mac without a battery.
private func battery() -> (level: Double, plugged: Bool)? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
              d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        return (Double(cur) / Double(max), d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
    }
    return nil
}

private let musicApps: Set<String> = ["com.spotify.client", "com.apple.Music"]

// MARK: - The world: your screens and windows, as ledges Mochi can stand on

/// An app window, in Cocoa screen coordinates (origin at the bottom-left of the main screen, y up).
struct Win { let id: Int; let pid: pid_t; let frame: CGRect }

/// Something flat to stand on: the bottom of a screen (win 0) or the uncovered part of a window's top edge.
struct Ledge { let x0: CGFloat; let x1: CGFloat; let y: CGFloat; let win: Int }

/// A hop in progress: a parabola from `from` to `to`.
struct Leap { let from: CGPoint; let to: CGPoint; let height: CGFloat; let dur: Double; var t: Double; let win: Int; let event: String? }

private func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
}

/// Every normal app window on every screen, front to back. Only positions: titles and contents would need Screen Recording.
/// Windows exactly the size of a screen come back separately: those are fullscreen apps, or invisible overlays some apps put up.
private func onScreenWindows() -> (windows: [Win], covering: [Win]) {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return ([], []) }
    let screens = NSScreen.screens
    let h0 = screens.first?.frame.height ?? 0
    let me = ProcessInfo.processInfo.processIdentifier
    var wins: [Win] = [], covering: [Win] = []
    for w in list {
        guard w[kCGWindowLayer as String] as? Int == 0,
              let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
              let id = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width >= 80, r.height >= 40 else { continue }
        let win = Win(id: id, pid: pid, frame: CGRect(x: r.minX, y: h0 - r.maxY, width: r.width, height: r.height))
        if screens.contains(where: { sameRect($0.frame, win.frame) }) { covering.append(win) } else { wins.append(win) }
    }
    return (wins, covering)
}

private func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
    hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
}

// MARK: - Window

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // AppKit keeps a window's top edge under the menu bar. This window is much taller than Mochi, so that would stop
    // Mochi well short of the top of the screen and sink it into windows near the top. Mochi keeps itself on screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class PetWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var panel: PetPanel!
    var web: PetWebView!

    // Mochi is drawn 46×34 "pixels", each `scale` points wide. The window adds room for a speech bubble above it
    // and, for when it's perched near the top of a screen, below it. Everything but Mochi and its bubble lets clicks through.
    static let below: CGFloat = 190
    var scale: CGFloat = 3
    var size: NSSize { NSSize(width: max(46 * scale, 250) + 260, height: App.below + 22 * scale + 196) }
    var footInset: CGFloat { App.below + 2 * scale }   // window bottom → Mochi's feet

    var hot: [CGRect] = []
    var ignoring = true
    var inside = false
    var pressed = false
    var dragMoved = false
    var dragMouse = NSPoint.zero
    var dragFoot = CGPoint.zero
    var mouse: [(t: Double, p: CGPoint)] = []    // the last 0.8 s of pointer positions
    var mouseMovedAt = 0.0
    var lastLook = ""
    var lastRoom = ""
    var frameCount = 0
    var lastFrame = CACurrentMediaTime()

    enum Motion: String { case still, walk, crouch, jump, fall, drag, poof }
    var motion = Motion.still
    var foot = CGPoint.zero        // where Mochi's feet are, in screen coordinates
    var vel = CGVector.zero
    var standing: Int?             // the window it's standing on, 0 for a screen's floor, nil in the air
    var facing: CGFloat = 1
    var walkTo: CGFloat = 0
    var leap: Leap?
    var crouchUntil = 0.0
    var windows: [Win] = []
    var ledges: [Ledge] = []
    var worldAt = 0.0
    var riding = false
    var roamLevel = 0              // from the page: 0 stay put, 1 the odd stroll, 2 you're away so go play
    let forcedRoam = ProcessInfo.processInfo.environment["MOCHI_ROAM"].flatMap { Int($0) }   // testing: pin the roam level, log moves
    var nextRoam = CACurrentMediaTime() + 20
    var otherScreenSince = 0.0
    var travelAt = 0.0, hopAt = 0.0, pounceAt = 0.0, dizzyAt = 0.0
    var userIdle = 0.0
    var fullscreen = false
    var lastSys = ""
    var ticks = 0

    var mood = "waking up"
    var stats: [String: Any] = [:]
    var wearing = ""
    lazy var sheet = PanelController(webDir: webDir)
    var quiet = false
    var awaySince: Date?
    var activity: NSObjectProtocol?
    var renderer: Renderer?

    let defaults = UserDefaults.standard
    var roam: Bool { defaults.object(forKey: "roam") as? Bool ?? true }
    var appAware: Bool { defaults.object(forKey: "appAware") as? Bool ?? true }
    var emoji: Bool { defaults.bool(forKey: "emoji") }   // off: pixel icons in the bubble
    var waterReminders: Bool { defaults.object(forKey: "waterReminders") as? Bool ?? true }
    var followClaude: Bool { defaults.object(forKey: "followClaude") as? Bool ?? true }
    var narrateClaude: Bool { defaults.object(forKey: "narrateClaude") as? Bool ?? true }
    var checkUsage: Bool { defaults.object(forKey: "checkUsage") as? Bool ?? true }   // ask Claude Code for usage every 5 minutes
    lazy var claude = ClaudeCode(dataDir: dataDir)
    lazy var claudeLinked = claude.connected
    var lastClaude = ""
    var claudeState = ""
    var attentionAt = 0.0
    lazy var dataDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mochi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    var stateURL: URL { dataDir.appendingPathComponent("state.json") }
    var webDir: URL { Bundle.main.resourceURL!.appendingPathComponent("web") }

    func applicationDidFinishLaunching(_ note: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--render") {
            let out = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : FileManager.default.currentDirectoryPath + "/renders"
            renderer = Renderer(webDir: webDir, outDir: URL(fileURLWithPath: out))
            renderer?.start()
            return
        }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Mochi keeps you company")
        scale = CGFloat(defaults.object(forKey: "scale") as? Double ?? 3)
        foot = startFoot()
        refreshWorld(CACurrentMediaTime())
        if roam { snapDown() }
        if let r = forcedRoam { roamLevel = r; nextRoam = CACurrentMediaTime() + 3; rlog("ledges:", ledges.map { "\($0.win):\(Int($0.x0))-\(Int($0.x1))@\(Int($0.y))" }) }
        buildPanel()
        sheet.state = { [weak self] in self?.panelState() ?? [:] }
        sheet.act = { [weak self] in self?.perform($0) }
        sheet.opened = { [weak self] in self?.js("mochi.menu(\($0))") }
        observeSystem()
        claude.onChange = { [weak self] in
            self?.pushClaude()
            if self?.sheet.isOpen == true { self?.sheet.update() }
        }
        claude.start()
        if claudeLinked { try? claude.writeScripts() }   // keep the hook scripts current after an update
        if checkUsage { DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.claude.checkUsage() } }
        if !defaults.bool(forKey: "loginConfigured") {
            defaults.set(true, forKey: "loginConfigured")
            setOpenAtLogin(true)
        }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.frame() }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: window + web view

    func buildPanel() {
        let ucc = WKUserContentController()
        ucc.add(self, name: "mochi")
        var saved = "null"
        if let data = try? Data(contentsOf: stateURL), (try? JSONSerialization.jsonObject(with: data)) != nil, let s = String(data: data, encoding: .utf8) {
            saved = s
        }
        var env: [String: Any] = ["app": true, "boot": bootTime() * 1000, "launched": Date().timeIntervalSince1970 * 1000,
                                  "scale": scale, "w": size.width, "h": size.height, "below": App.below, "emoji": emoji,
                                  "water": waterReminders, "claude": followClaude, "narrate": narrateClaude]
        if let speed = ProcessInfo.processInfo.environment["MOCHI_SPEED"], let v = Double(speed) { env["speed"] = v }
        if ProcessInfo.processInfo.environment["MOCHI_TRACE"] != nil { env["trace"] = true }
        let boot = "window.MOCHI_SAVED = \(saved); window.MOCHI_ENV = \(json(env));"
        ucc.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let cfg = WKWebViewConfiguration()
        cfg.userContentController = ucc

        web = PetWebView(frame: NSRect(origin: .zero, size: size), configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.loadFileURL(webDir.appendingPathComponent("index.html"), allowingReadAccessTo: webDir)

        panel = PetPanel(contentRect: NSRect(origin: origin(), size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.contentView = web
        if !defaults.bool(forKey: "hidden") { panel.orderFrontRegardless() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastSys = ""
        lastRoom = ""
        lastClaude = ""
        pushSys()
        sendRoom()
        pushClaude()
        // Claude Code is on this Mac but not connected yet: offer once
        if claude.hasClaudeCode && !claude.connected && !defaults.bool(forKey: "claudeOffered") {
            defaults.set(true, forKey: "claudeOffered")
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.js("mochi.claudeHint()") }
        }
    }

    func js(_ code: String) { web?.evaluateJavaScript(code, completionHandler: nil) }
    func send(_ state: String) {
        if forcedRoam != nil { rlog(String(format: "%.1f %@ at (%.0f, %.0f) on %@", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000), state, foot.x, foot.y, standing.map(String.init) ?? "-")) }
        js("mochi.move('\(state)', \(Int(facing)))")
    }
    func event(_ name: String) { js("mochi.event('\(name)')") }

    func screen(at p: CGPoint) -> NSScreen? { NSScreen.screens.first { $0.frame.insetBy(dx: -0.5, dy: -0.5).contains(p) } }
    func nearestScreen(_ p: CGPoint) -> NSScreen { NSScreen.screens.min { distance($0.frame, p) < distance($1.frame, p) } ?? NSScreen.screens[0] }

    func defaultFoot() -> CGPoint {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return CGPoint(x: vf.maxX - 150, y: vf.minY)
    }

    func startFoot() -> CGPoint {
        let p: CGPoint
        if defaults.object(forKey: "footX") != nil { p = CGPoint(x: defaults.double(forKey: "footX"), y: defaults.double(forKey: "footY")) }
        else if defaults.object(forKey: "x") != nil { p = CGPoint(x: defaults.double(forKey: "x") + 160, y: defaults.double(forKey: "y") + 12) } // where 1.0 left it
        else { return defaultFoot() }
        return screen(at: p) != nil ? p : defaultFoot()
    }

    func origin() -> NSPoint { NSPoint(x: (foot.x - size.width / 2).rounded(), y: (foot.y - footInset).rounded()) }

    func place() {
        let o = origin()
        if o != panel.frame.origin { panel.setFrameOrigin(o) }
        if frameCount % 4 == 0 { sendRoom() }
    }

    /// Tells the page how much screen there is around Mochi, so the speech bubble never ends up off-screen.
    func sendRoom() {
        guard let s = screen(at: foot) ?? NSScreen.screens.first else { return }
        let above = s.visibleFrame.maxY - (foot.y + 20 * scale + 6)
        let left = foot.x - s.frame.minX, right = s.frame.maxX - foot.x
        let key = "\(Int(above / 8)),\(Int(left / 8)),\(Int(right / 8))"
        if key != lastRoom { lastRoom = key; js("window.mochi && mochi.room(\(Int(above)),\(Int(left)),\(Int(right)))") }
    }

    func saveSpot() {
        defaults.set(Double(foot.x), forKey: "footX")
        defaults.set(Double(foot.y), forKey: "footY")
    }

    // 60 Hz: getting around, dragging, click-through, and where your cursor is (so Mochi can look at it)
    func frame() {
        guard let panel, panel.isVisible else { return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastFrame, 0.05)
        lastFrame = now
        let m = NSEvent.mouseLocation
        if let last = mouse.last, hypot(last.p.x - m.x, last.p.y - m.y) > 1 { mouseMovedAt = now }
        mouse.append((now, m))
        mouse.removeAll { now - $0.t > 0.8 }
        let yours = screen(at: m)?.frame
        if yours != nil && yours != screen(at: foot)?.frame { if otherScreenSince == 0 { otherScreenSince = now } } else { otherScreenSince = 0 }

        frameCount += 1
        // ride along with a moving window smoothly; otherwise the windows don't need checking as often
        if frameCount % ((standing ?? 0) > 0 || motion == .fall ? 3 : 12) == 0 { refreshWorld(now) }
        handleDrag(m, now)
        step(dt, now)
        if roam && motion == .still { roamAround(m, now) }
        place()

        let f = panel.frame
        let x = m.x - f.minX, y = f.maxY - m.y
        inside = hot.contains { $0.contains(CGPoint(x: x, y: y)) }
        let ignore = !(inside || pressed)
        if ignore != ignoring { ignoring = ignore; panel.ignoresMouseEvents = ignore }

        if frameCount % 4 == 0 {
            let key = "\(Int(x)),\(Int(y)),\(inside)"
            if key != lastLook { lastLook = key; js("mochi.look(\(Int(x)),\(Int(y)),\(inside))") }
            checkWiggle(m, now)
        }
    }

    // 1 Hz: how long since you last touched the keyboard or mouse; every 2 s, what the Mac is up to
    func tick() {
        let mouse = [CGEventType.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged].map(idle).min() ?? 0
        userIdle = idle(anyInput)
        let payload: [String: Any] = [
            "now": Date().timeIntervalSince1970 * 1000,
            "idle": userIdle,
            "kbIdle": min(idle(.keyDown), idle(.flagsChanged)),
            "mouseIdle": mouse,
        ]
        js("window.mochi && mochi.tick(\(json(payload)))")
        ticks += 1
        if ticks % 2 == 0 { pushSys() }
        claude.prune()
        pushClaude()
        if ticks % 300 == 0 && checkUsage { claude.checkUsage() }   // and every 5 minutes, fresh numbers
    }

    /// Which app you're in, calls, fullscreen, music, battery, dark mode. Sent only when something changes.
    func pushSys() {
        var d: [String: Any] = ["dark": NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua]
        if let b = battery() { d["battery"] = (b.level * 100).rounded() / 100; d["plugged"] = b.plugged }
        if appAware {
            d["app"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            d["camera"] = cameraInUse()
            d["mic"] = audioInUse(input: true)
            d["fullscreen"] = fullscreen
            d["music"] = audioInUse(input: false) && NSWorkspace.shared.runningApplications.contains { musicApps.contains($0.bundleIdentifier ?? "") }
        }
        let s = json(d)
        if s != lastSys { lastSys = s; js("window.mochi && mochi.sys(\(s))") }
    }

    // MARK: Claude Code

    /// Tells the page what Claude Code is up to, when that changes.
    func pushClaude() {
        let d = claude.payload()
        let s = json(d)
        guard s != lastClaude else { return }
        lastClaude = s
        js("window.mochi && mochi.claude(\(s))")
        let state = d["state"] as? String ?? ""
        // Claude needs you: come over to where your pointer is, so you notice
        if state == "waiting" && claudeState != "waiting" && followClaude && roam && motion == .still && panel.isVisible {
            let now = CACurrentMediaTime()
            if now - attentionAt > 45 { attentionAt = now; visitPointer(NSEvent.mouseLocation) }
        }
        claudeState = state
    }

    @objc func connectClaude() {
        let on = !claude.connected
        do {
            try claude.connect(on)
            claudeLinked = on
            if on { js("mochi.claudeConnected(true, '')") }
        } catch {
            NSLog("[mochi] claude: %@", error.localizedDescription)
            js("mochi.claudeConnected(false, \(json([error.localizedDescription]))[0])")
        }
    }

    @objc func toggleFollowClaude() {
        defaults.set(!followClaude, forKey: "followClaude")
        js("mochi.setClaude(\(followClaude), \(narrateClaude))")
    }

    /// Opening the panel with numbers more than a minute old asks for new ones.
    func freshenUsage() {
        guard checkUsage, (claude.usageAt.map { Date().timeIntervalSince($0) > 60 } ?? true) else { return }
        claude.checkUsage()
    }

    @objc func toggleNarrateClaude() {
        defaults.set(!narrateClaude, forKey: "narrateClaude")
        js("mochi.setClaude(\(followClaude), \(narrateClaude))")
    }

    // MARK: getting around

    /// Re-reads the windows, rides along if the one Mochi's on moved, and drops it if it closed or got covered.
    func refreshWorld(_ now: Double) {
        let before = windows
        let (wins, covering) = onScreenWindows()
        windows = wins
        ledges = buildLedges()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let fs = covering.contains { $0.pid == front }
        if fs != fullscreen { fullscreen = fs; pushSys() }
        let dtw = max(now - worldAt, 0.016)
        worldAt = now
        guard roam, panel != nil, motion == .still || motion == .walk, let on = standing else { return }
        if on > 0 {
            guard let w = windows.first(where: { $0.id == on }) else { return startFall(event: "gone") }
            if let old = before.first(where: { $0.id == on }) {
                let dx = w.frame.minX - old.frame.minX, dy = w.frame.maxY - old.frame.maxY
                if dx != 0 || dy != 0 {
                    if hypot(dx, dy) / dtw > 2800 {   // yanked out from under it: knocked off, flung a little the way the window went
                        return startFall(vx: min(max(dx / dtw * 0.3, -700), 700), vy: min(max(0, dy / dtw) * 0.3, 700) + 300, event: "knocked")
                    }
                    foot.x += dx
                    foot.y += dy
                    walkTo += dx
                    if !riding { riding = true; event("ride") }
                } else {
                    riding = false
                }
            }
        } else {
            let s = screen(at: foot) ?? nearestScreen(foot)
            if s.visibleFrame.minY > foot.y && s.visibleFrame.minY - foot.y < 200 { foot.y = s.visibleFrame.minY } // the Dock came up
        }
        if ledge(under: foot) == nil { startFall(event: on > 0 ? "gone" : nil) }
    }

    func buildLedges() -> [Ledge] {
        let screens = NSScreen.screens
        var out = screens.map { Ledge(x0: $0.frame.minX, x1: $0.frame.maxX, y: $0.visibleFrame.minY, win: 0) }
        let headroom = 13 * scale, minLen = 16 * scale
        for (i, w) in windows.enumerated() {
            let y = w.frame.maxY
            let s = [w.frame.midX, w.frame.minX + 20, w.frame.maxX - 20].lazy.compactMap { self.screen(at: CGPoint(x: $0, y: y - 1)) }.first
            // a window that reaches up to the menu bar has no room on top for Mochi
            guard let s, y + headroom <= s.visibleFrame.maxY, y > s.visibleFrame.minY + 4 * scale else { continue }
            var segs = [(max(w.frame.minX, s.frame.minX), min(w.frame.maxX, s.frame.maxX))]
            for f in windows[..<i] where f.frame.minY < y + headroom * 0.6 && f.frame.maxY > y - 2 {
                segs = segs.flatMap { seg -> [(CGFloat, CGFloat)] in
                    guard f.frame.maxX > seg.0 && f.frame.minX < seg.1 else { return [seg] }
                    return [(seg.0, f.frame.minX), (f.frame.maxX, seg.1)].filter { $0.1 > $0.0 }
                }
            }
            out += segs.filter { $0.1 - $0.0 >= minLen }.map { Ledge(x0: $0.0, x1: $0.1, y: y, win: w.id) }
        }
        return out
    }

    func ledge(under p: CGPoint, prefer: Int? = nil) -> Ledge? {
        let slack = 3 * scale
        let hits = ledges.filter { abs($0.y - p.y) <= 2 && p.x >= $0.x0 - slack && p.x <= $0.x1 + slack }
        return hits.first { $0.win == (prefer ?? standing) } ?? hits.max { $0.y < $1.y }
    }

    /// Drops Mochi straight onto whatever is below it, without the fall.
    func snapDown() {
        if let l = ledges.filter({ $0.y <= foot.y + 2 && foot.x >= $0.x0 && foot.x <= $0.x1 }).max(by: { $0.y < $1.y }) {
            foot.y = l.y
            standing = l.win
        } else {
            foot = defaultFoot()
            standing = 0
        }
    }

    func step(_ dt: Double, _ now: Double) {
        let t = CGFloat(dt)
        switch motion {
        case .still, .drag, .poof:
            break
        case .walk:
            let dir: CGFloat = walkTo >= foot.x ? 1 : -1
            let d = t * 10 * scale
            if abs(walkTo - foot.x) <= d { foot.x = walkTo; return settle(nil, landed: false) }
            foot.x += dir * d
            if let l = ledge(under: foot) { foot.y = l.y; standing = l.win }
            else if let up = ledges.filter({ $0.y > foot.y && $0.y - foot.y <= 4 * scale && foot.x >= $0.x0 && foot.x <= $0.x1 }).min(by: { $0.y < $1.y }) {
                foot.y = up.y   // a little step up
                standing = up.win
            } else {
                startFall(vx: dir * 10 * scale)
            }
        case .crouch:
            if now >= crouchUntil { motion = .jump; send("jump") }
        case .jump:
            guard var j = leap else { return startFall() }
            j.t += dt
            leap = j
            let u = CGFloat(min(1, j.t / j.dur))
            foot = CGPoint(x: j.from.x + (j.to.x - j.from.x) * u, y: j.from.y + (j.to.y - j.from.y) * u + j.height * 4 * u * (1 - u))
            if u >= 1 {
                leap = nil
                if let l = ledge(under: j.to, prefer: j.win) { settle(l, landed: true, event: j.event) } else { startFall() }
            }
        case .fall:
            let prevY = foot.y
            vel.dy = max(vel.dy - 2600 * t, -1800)
            vel.dx *= CGFloat(pow(0.5, dt))
            foot.x += vel.dx * t
            foot.y += vel.dy * t
            keepOnScreens()
            if vel.dy <= 0, let l = ledges.filter({ $0.y <= prevY + 0.5 && $0.y >= foot.y && foot.x >= $0.x0 && foot.x <= $0.x1 }).max(by: { $0.y < $1.y }) {
                settle(l, landed: true)
            }
        }
    }

    /// Bounces a thrown Mochi off the outer edges of your screens and the tops of them.
    func keepOnScreens() {
        let head = 14 * scale
        if let s = screen(at: foot) {
            if foot.y > s.frame.maxY - head { foot.y = s.frame.maxY - head; vel.dy = min(vel.dy, 0) }
            return
        }
        let s = nearestScreen(foot), f = s.frame
        if foot.x < f.minX { foot.x = f.minX + 1; vel.dx = abs(vel.dx) * 0.4 }
        if foot.x > f.maxX { foot.x = f.maxX - 1; vel.dx = -abs(vel.dx) * 0.4 }
        if foot.y > f.maxY - head { foot.y = f.maxY - head; vel.dy = min(vel.dy, 0) }
        if foot.y < s.visibleFrame.minY { foot.y = s.visibleFrame.minY }
    }

    func settle(_ l: Ledge?, landed: Bool, event name: String? = nil) {
        motion = .still
        vel = .zero
        riding = false
        if let l { foot.y = l.y; standing = l.win }
        send(landed ? "land" : "still")
        if let name { event(name) }
        saveSpot()
    }

    func startFall(vx: CGFloat = 0, vy: CGFloat = 0, event name: String? = nil) {
        motion = .fall
        vel = CGVector(dx: vx, dy: vy)
        standing = nil
        leap = nil
        riding = false
        send("fall")
        if let name { event(name) }
    }

    func walk(to x: CGFloat) {
        guard abs(x - foot.x) > 2 else { return }
        walkTo = x
        facing = x > foot.x ? 1 : -1
        motion = .walk
        send("walk")
    }

    func hop(to p: CGPoint, win: Int, height: CGFloat? = nil, event: String? = nil) {
        let dist = hypot(p.x - foot.x, p.y - foot.y)
        if forcedRoam != nil { rlog(String(format: "hop to (%.0f, %.0f) on %d, %.0f away; ledges %@", p.x, p.y, win, dist, ledges.map { "\($0.win):\(Int($0.x0))-\(Int($0.x1))@\(Int($0.y))" }.joined(separator: " "))) }
        if dist > 1400 { return poof(to: p, win: win, event: event) }
        let h = height ?? (max(0, p.y - foot.y) + 30 + dist * 0.12)
        leap = Leap(from: foot, to: p, height: h, dur: min(1.1, 0.42 + Double(dist) / 1500 + Double(h) / 2000), t: 0, win: win, event: event)
        if abs(p.x - foot.x) > 1 { facing = p.x > foot.x ? 1 : -1 }
        standing = nil
        motion = .crouch
        crouchUntil = CACurrentMediaTime() + 0.22
        send("crouch")
    }

    /// Too far to jump: vanish in a puff of sparkles and reappear there.
    func poof(to p: CGPoint, win: Int, event: String?) {
        motion = .poof
        standing = nil
        self.event("poof")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: {
            self.foot = p
            self.place()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self.panel.animator().alphaValue = 1
            }
            if let l = self.ledge(under: p, prefer: win) { self.settle(l, landed: true, event: event ?? "arrive") } else { self.startFall() }
        })
    }

    func stroll(far: Bool) {
        guard let l = ledge(under: foot) else { return }
        var x = foot.x + CGFloat.random(in: far ? 20...70 : 8...36) * scale * (Bool.random() ? 1 : -1)
        // now and then, walk right off the end of a window just to see what happens
        if !(far && l.win != 0 && Double.random(in: 0..<1) < 0.25) { x = min(max(x, l.x0 + 5 * scale), l.x1 - 5 * scale) }
        walk(to: x)
    }

    /// Hops onto some other window (mostly on this screen), or back down to the floor.
    func explore() {
        let here = screen(at: foot)?.frame
        let spots = ledges.filter { $0.win != 0 && $0.win != standing && $0.x1 - $0.x0 >= 16 * scale }
        let near = spots.filter { screen(at: CGPoint(x: ($0.x0 + $0.x1) / 2, y: $0.y - 1))?.frame == here }
        let pool = near.isEmpty || Double.random(in: 0..<1) < 0.2 ? spots : near
        let onWindow = (standing ?? 0) > 0
        if pool.isEmpty || (onWindow && Double.random(in: 0..<1) < 0.3) {
            guard onWindow, let s = screen(at: foot) else { return stroll(far: true) }
            let x = min(max(foot.x + .random(in: -120...120), s.frame.minX + 40), s.frame.maxX - 40)
            return hop(to: CGPoint(x: x, y: s.visibleFrame.minY), win: 0)
        }
        if let l = pool.randomElement() { hop(to: CGPoint(x: .random(in: (l.x0 + 6 * scale)...(l.x1 - 6 * scale)), y: l.y), win: l.win) }
    }

    /// Hops up onto the top edge of the window you're using, near its right corner. False if there's no room up there.
    @discardableResult func perchOnFrontWindow() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let w = windows.first(where: { $0.pid == pid }),
              let l = ledges.filter({ $0.win == w.id }).max(by: { $0.x1 - $0.x0 < $1.x1 - $1.x0 }) else { return false }
        if standing == w.id { return true }
        let x = l.x1 - CGFloat.random(in: 8...min(40, (l.x1 - l.x0) / scale - 8)) * scale
        hop(to: CGPoint(x: x, y: l.y), win: l.win)
        return true
    }

    /// Goes and stands under your pointer.
    func visitPointer(_ m: CGPoint) {
        guard let l = ledges.filter({ m.x >= $0.x0 && m.x <= $0.x1 && $0.y <= m.y && m.y - $0.y < 500 }).max(by: { $0.y < $1.y }) else { return }
        let x = min(max(m.x, l.x0 + 5 * scale), l.x1 - 5 * scale)
        if l.win == standing && abs(l.y - foot.y) < 2 && abs(x - foot.x) < 360 { walk(to: x) } else { hop(to: CGPoint(x: x, y: l.y), win: l.win) }
    }

    /// Mochi's own ideas, when it's standing around with nothing to do.
    func roamAround(_ m: CGPoint, _ now: Double) {
        guard roamLevel > 0, !inside, !pressed, !sheet.isOpen else { return }
        // your pointer just stopped right above Mochi's head: jump for it
        let still = now - mouseMovedAt
        if still > 1.2, still < 6, now > pounceAt, abs(m.x - foot.x) < 10 * scale, m.y - foot.y > 14 * scale, m.y - foot.y < 14 * scale + 160 {
            pounceAt = now + 40
            return hop(to: foot, win: standing ?? 0, height: m.y - foot.y - 8 * scale, event: "pounce")
        }
        // you've been on another screen for a while: come along
        if let yours = screen(at: m), otherScreenSince > 0, now - otherScreenSince > 40, now > travelAt, userIdle < 5 {
            travelAt = now + 120
            otherScreenSince = 0
            let f = yours.frame
            return hop(to: CGPoint(x: min(max(m.x, f.minX + 140), f.maxX - 140), y: yours.visibleFrame.minY), win: 0, event: "arrive")
        }
        guard now >= nextRoam else { return }
        nextRoam = now + (roamLevel >= 2 ? .random(in: 5...14) : .random(in: 25...75))
        let r = Double.random(in: 0..<1)
        if roamLevel >= 2 {
            if r < 0.4 { stroll(far: true) } else if r < 0.85 { explore() }
        } else {
            if r < 0.5 { stroll(far: false) } else if r < 0.68 { perchOnFrontWindow() } else if r < 0.82 { visitPointer(m) }
        }
    }

    func handleDrag(_ m: CGPoint, _ now: Double) {
        guard pressed else { return }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            pressed = false
            guard dragMoved else { js("mochi.dragEnd(false, false)"); return }
            // let go while moving: throw it
            let recent = mouse.filter { now - $0.t < 0.08 }
            var v = CGVector.zero
            if let a = recent.first, let b = recent.last, b.t - a.t > 0.01 {
                v = CGVector(dx: (b.p.x - a.p.x) / (b.t - a.t), dy: (b.p.y - a.p.y) / (b.t - a.t))
            }
            let speed = hypot(v.dx, v.dy)
            if speed > 2400 { v.dx *= 2400 / speed; v.dy *= 2400 / speed }
            js("mochi.dragEnd(true, \(roam))")
            if roam { startFall(vx: v.dx, vy: v.dy) } else { motion = .still; saveSpot() }
        } else {
            let dx = m.x - dragMouse.x, dy = m.y - dragMouse.y
            if !dragMoved && hypot(dx, dy) > 3 {
                dragMoved = true
                motion = .drag
                standing = nil
                leap = nil
                js("mochi.dragging()")
            }
            if dragMoved { foot = CGPoint(x: dragFoot.x + dx, y: dragFoot.y + dy) }
        }
    }

    /// Wiggling the pointer back and forth right next to Mochi makes it dizzy.
    func checkWiggle(_ m: CGPoint, _ now: Double) {
        guard now > dizzyAt, !pressed, hypot(m.x - foot.x, m.y - foot.y - 6 * scale) < 260 else { return }
        var flips = 0
        var last: CGFloat = 0
        for (a, b) in zip(mouse, mouse.dropFirst()) {
            let dx = b.p.x - a.p.x
            guard abs(dx) > 3 else { continue }
            let s: CGFloat = dx > 0 ? 1 : -1
            if last != 0 && s != last { flips += 1 }
            last = s
        }
        if flips >= 5 { dizzyAt = now + 10; js("mochi.dizzy()") }
    }

    // MARK: messages from the page

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "hot":
            hot = (body["rects"] as? [[Double]] ?? []).compactMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        case "dragStart":
            sheet.close()
            pressed = true
            dragMoved = false
            dragMouse = NSEvent.mouseLocation
            dragFoot = foot
        case "roam":
            roamLevel = forcedRoam ?? body["level"] as? Int ?? 0
            if roamLevel == 0 && motion == .walk { settle(nil, landed: false) }
            if roamLevel >= 2 { nextRoam = min(nextRoam, CACurrentMediaTime() + 4) }
        case "menu":
            sheet.show(x: foot.x, top: foot.y + 15 * scale, feet: foot.y)
            freshenUsage()
        case "save":
            if let s = body["data"] as? String { try? s.write(to: stateURL, atomically: true, encoding: .utf8) }
        case "stats":
            stats = body["stats"] as? [String: Any] ?? [:]
            mood = body["mood"] as? String ?? mood
            wearing = body["wearing"] as? String ?? ""
            quiet = body["quiet"] as? Bool ?? false
            if sheet.isOpen { sheet.update() }
        case "log":
            let msg = String(describing: body["msg"] ?? "")
            if ProcessInfo.processInfo.environment["MOCHI_TRACE"] != nil { rlog(msg) } else { NSLog("[mochi] %@", msg) }
        case "claudeFocus":
            claude.focus(nil)
        case "claudeConnect":
            if !claude.connected { connectClaude() }
        default:
            break
        }
    }

    // MARK: sleep, wake, lock, apps, screens

    func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        let away: (Notification) -> Void = { [weak self] _ in if self?.awaySince == nil { self?.awaySince = Date() } }
        let back: (Notification) -> Void = { [weak self] _ in
            guard let self, let since = self.awaySince else { return }
            self.awaySince = nil
            self.js("mochi.onWake(\(Int(Date().timeIntervalSince(since))))")
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: away)
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: away)
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: back)
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.pushSys()
            // sometimes hop onto the window you just switched to
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let now = CACurrentMediaTime()
                guard self.roam, self.roamLevel > 0, self.motion == .still, now > self.hopAt, Double.random(in: 0..<1) < 0.35 else { return }
                self.hopAt = now + 90
                self.perchOnFrontWindow()
            }
        }
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: away)
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: back)
        dn.addObserver(forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.pushSys() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lastRoom = ""
            if self.screen(at: self.foot) == nil { self.resetPosition() } else { self.refreshWorld(CACurrentMediaTime()) }
        }
    }

    // MARK: the panel

    /// Everything the panel shows, as of now, for web/panel.js.
    func panelState() -> [String: Any] {
        func usage(_ w: UsageWindow?) -> Any {
            guard let w else { return NSNull() }
            return ["pct": w.pct, "resets": w.resets.map(PanelController.when) ?? ""]
        }
        var updated = ""
        if let at = claude.usageAt {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            updated = Date().timeIntervalSince(at) < 60 ? "updated just now" : "updated " + f.localizedString(for: at, relativeTo: Date())
        }
        return [
            "tab": defaults.string(forKey: "panelTab") ?? "claude", "mood": mood, "stats": stats, "wearing": wearing,
            "visible": panel.isVisible, "quiet": quiet, "roam": roam, "appAware": appAware, "emoji": emoji, "water": waterReminders,
            "login": SMAppService.mainApp.status == .enabled, "scale": Double(scale),
            "follow": followClaude, "narrate": narrateClaude, "checkUsage": checkUsage, "canCheck": ClaudeCode.binary != nil,
            "connected": claudeLinked, "listening": claude.listening, "port": Int(ClaudeCode.port),
            "five": usage(claude.current(claude.fiveHour)), "week": usage(claude.current(claude.weekly)), "updated": updated,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        ]
    }

    func perform(_ a: PanelAction) {
        switch a {
        case .pet(let id): petAction(id)
        case .size(let s): setSize(s)
        case .roam: toggleRoam()
        case .appAware: toggleAppAware()
        case .emoji: toggleEmoji()
        case .water: toggleWater()
        case .quiet: toggleQuiet()
        case .login: toggleLogin()
        case .corner: resetPosition()
        case .visible: toggleVisible()
        case .connect: connectClaude()
        case .follow: toggleFollowClaude()
        case .narrate: toggleNarrateClaude()
        case .checkUsage:
            defaults.set(!checkUsage, forKey: "checkUsage")
            if checkUsage { claude.checkUsage() }
        case .refreshUsage: claude.checkUsage()
        case .quit: NSApp.terminate(nil)
        }
        sheet.update()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // opening Mochi again brings it back: the only way back once it's hidden
        if !panel.isVisible { toggleVisible() }
        return false
    }

    func petAction(_ id: String) {
        if !panel.isVisible { toggleVisible() }
        switch id {
        case "perch":
            if !roam { toggleRoam() }
            if !perchOnFrontWindow() { event("noroom") }
        case "explore":
            if !roam { toggleRoam() }
            explore()
        default:
            js("mochi.action('\(id)')")
        }
    }

    func setSize(_ s: Double) {
        defaults.set(s, forKey: "scale")
        scale = CGFloat(s)
        js("mochi.setScale(\(s), \(Int(size.width)), \(Int(size.height)))")
        panel.setFrame(NSRect(origin: origin(), size: size), display: true)
        ledges = buildLedges()
        lastRoom = ""
    }

    @objc func toggleRoam() {
        defaults.set(!roam, forKey: "roam")
        if roam { startFall() } else if motion != .drag { leap = nil; settle(nil, landed: false) }
    }

    @objc func toggleAppAware() {
        defaults.set(!appAware, forKey: "appAware")
        pushSys()
    }

    @objc func toggleVisible() {
        if panel.isVisible { panel.orderOut(nil); defaults.set(true, forKey: "hidden") }
        else { panel.orderFrontRegardless(); defaults.set(false, forKey: "hidden") }
    }

    @objc func toggleEmoji() {
        defaults.set(!emoji, forKey: "emoji")
        js("mochi.setEmoji(\(emoji))")
    }

    @objc func toggleWater() {
        defaults.set(!waterReminders, forKey: "waterReminders")
        js("mochi.setWater(\(waterReminders))")
    }

    @objc func toggleQuiet() {
        let until = quiet ? 0 : (Date().timeIntervalSince1970 + 3600) * 1000
        quiet.toggle()
        js("mochi.setQuiet(\(until))")
    }

    @objc func toggleLogin() { setOpenAtLogin(SMAppService.mainApp.status != .enabled) }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[mochi] open at login: %@", error.localizedDescription)
        }
    }

    @objc func resetPosition() {
        foot = defaultFoot()
        standing = 0
        leap = nil
        vel = .zero
        motion = .still
        place()
        saveSpot()
        send("still")
        if !panel.isVisible { toggleVisible() }
    }
}

func rlog(_ items: Any...) { FileHandle.standardError.write((items.map { "\($0)" }.joined(separator: " ") + "\n").data(using: .utf8)!) }

// MARK: - Render mode: `Mochi --render <dir>` saves every pose as a PNG

final class Renderer: NSObject, WKNavigationDelegate {
    let webDir: URL
    let outDir: URL
    var window: NSWindow!
    var web: WKWebView!
    var poses: [String] = []
    var index = 0
    let size = NSSize(width: 276, height: 204)

    init(webDir: URL, outDir: URL) {
        self.webDir = webDir
        self.outDir = outDir
    }

    func start() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.addUserScript(WKUserScript(source: "window.MOCHI_RENDER = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = web
        window.orderFrontRegardless()
        let url = webDir.appendingPathComponent("index.html")
        web.loadFileURL(url, allowingReadAccessTo: webDir)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { rlog("could not load the page:", error); NSApp.terminate(nil) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.evaluateJavaScript("renderList()") { result, _ in
            self.poses = result as? [String] ?? []
            self.next()
        }
    }

    func next() {
        guard index < poses.count else { rlog("rendered \(poses.count) poses to \(outDir.path)"); NSApp.terminate(nil); return }
        let pose = poses[index]
        web.evaluateJavaScript("renderPose('\(pose)')") { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                let cfg = WKSnapshotConfiguration()
                cfg.snapshotWidth = NSNumber(value: Double(self.size.width) * 2)
                self.web.takeSnapshot(with: cfg) { image, _ in
                    if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: self.outDir.appendingPathComponent("\(pose).png"))
                    }
                    self.index += 1
                    self.next()
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
