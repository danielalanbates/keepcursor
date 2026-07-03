// KeepCursor — keeps the macOS mouse cursor visible in World of Warcraft
// (and other full-screen games) after Command-Tab / alt-tab.
//
// THE BUG
// On macOS, switching out of WoW and back (or an alert popping over it) can
// leave the in-game cursor invisible. Three things go wrong at once:
//   1. The WindowServer per-app cursor hide/show counter gets driven negative,
//      so a single CGDisplayShowCursor() won't bring it back.
//   2. The mouse can stay "disassociated" from the cursor after a camera grab.
//   3. The hardware cursor sprite is not repainted, so even a balanced counter
//      shows nothing until the cursor moves.
//
// THE FIX (restore burst)
//   - Call CGDisplayShowCursor several times to unwind the negative counter.
//   - CGAssociateMouseAndMouseCursorPosition(true) to re-link mouse + cursor.
//   - Warp the cursor by 1px and back to force WindowServer to repaint it.
// The burst fires exactly on the activation event (WoW comes to the front),
// plus a light safety re-check while WoW is frontmost. This is why it works
// where a dumb once-per-second CGDisplayShowCursor timer does not.
//
// No Accessibility / Input Monitoring permission required.

import AppKit
import CoreGraphics
import ServiceManagement
import Carbon.HIToolbox

// MARK: - Settings

enum Keys {
    static let enabled = "enabled"
    static let watchAllGames = "watchAllGames"
    static let keepSize = "keepSize"
    static let cursorScale = "cursorScale"
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    init() {
        d.register(defaults: [
            Keys.enabled: true,
            Keys.watchAllGames: false,
            Keys.keepSize: true,
            Keys.cursorScale: 2.0,   // 2nd-from-bottom on the 1.0–4.0 scale
        ])
    }
    var enabled: Bool {
        get { d.bool(forKey: Keys.enabled) }
        set { d.set(newValue, forKey: Keys.enabled) }
    }
    var watchAllGames: Bool {
        get { d.bool(forKey: Keys.watchAllGames) }
        set { d.set(newValue, forKey: Keys.watchAllGames) }
    }
    /// When on, KeepCursor pins the system cursor size to `cursorScale`,
    /// re-applying it whenever something (e.g. a game's display-mode switch)
    /// resets it back to the smallest size.
    var keepSize: Bool {
        get { d.bool(forKey: Keys.keepSize) }
        set { d.set(newValue, forKey: Keys.keepSize) }
    }
    /// Desired cursor scale, 1.0 (smallest) … 4.0 (largest).
    var cursorScale: Double {
        get { min(4.0, max(1.0, d.double(forKey: Keys.cursorScale))) }
        set { d.set(min(4.0, max(1.0, newValue)), forKey: Keys.cursorScale) }
    }
}

// MARK: - Cursor size (SkyLight private API)
//
// The Accessibility "Pointer size" preference (mouseDriverCursorSize) is
// DECOUPLED from the live WindowServer cursor scale on current macOS — writing
// the pref does not change the rendered cursor. The only reliable lever is
// SkyLight's CGSGetCursorScale / CGSSetCursorScale. A display-mode change
// (common when a full-screen game launches / alt-tabs) resets the live scale
// back to 1.0, which is why the cursor felt "permanently stuck smallest".

enum CursorScale {
    typealias ConnID = UInt32
    private typealias MainConnFn = @convention(c) () -> ConnID
    private typealias GetFn = @convention(c) (ConnID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (ConnID, Float) -> Int32

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func sym<T>(_ name: String) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let mainConn: MainConnFn? = sym("CGSMainConnectionID")
    private static let getFn: GetFn? = sym("CGSGetCursorScale")
    private static let setFn: SetFn? = sym("CGSSetCursorScale")

    static var available: Bool { mainConn != nil && getFn != nil && setFn != nil }

    static func current() -> Float? {
        guard let mc = mainConn, let g = getFn else { return nil }
        var s: Float = -1
        return g(mc(), &s) == 0 ? s : nil
    }
    static func set(_ value: Float) {
        guard let mc = mainConn, let st = setFn else { return }
        _ = st(mc(), max(1.0, min(4.0, value)))
    }
    /// Re-apply the target only if the live scale has drifted (avoids needless writes).
    static func enforce(_ target: Float) {
        guard let cur = current() else { set(target); return }
        if abs(cur - target) > 0.01 { set(target) }
    }
}

// MARK: - Cursor restoration

enum CursorFixer {
    // Bundle IDs that identify World of Warcraft (retail + classic share this).
    static let wowBundleIDs: Set<String> = ["com.blizzard.worldofwarcraft"]
    static let wowNameFragments = ["world of warcraft"]

    static func isWoW(_ app: NSRunningApplication) -> Bool {
        if let bid = app.bundleIdentifier?.lowercased(), wowBundleIDs.contains(bid) {
            return true
        }
        if let name = app.localizedName?.lowercased() {
            for frag in wowNameFragments where name.contains(frag) { return true }
        }
        return false
    }

    /// Heuristic for "some other full-screen game" when Watch-all-games is on.
    /// Two signals, either sufficient:
    ///   - a known game-host vendor (Blizzard / Steam), or
    ///   - the app owns an on-screen window covering the entire main display
    ///     (how full-screen games actually present).
    static func looksLikeFullscreenGame(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular else { return false }
        if let bid = app.bundleIdentifier?.lowercased(),
           bid.contains("blizzard") || bid.contains("valvesoftware.steam") {
            return true
        }
        return ownsFullscreenWindow(pid: app.processIdentifier)
    }

    /// True if `pid` owns an on-screen window whose bounds cover the main
    /// display. Finder/desktop layers are excluded by requiring layer 0..<20
    /// (normal app windows and full-screen game presentation layers).
    static func ownsFullscreenWindow(pid: pid_t) -> Bool {
        guard let screen = NSScreen.main else { return false }
        let target = CGRect(x: 0, y: 0,
                            width: screen.frame.width, height: screen.frame.height)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        for win in list {
            guard let owner = win[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = win[kCGWindowLayer as String] as? Int, layer >= 0, layer < 20,
                  let b = win[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0,
                              width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if rect.width >= target.width, rect.height >= target.height { return true }
        }
        return false
    }

    static func frontmostIsTarget() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if isWoW(front) { return true }
        if Settings.shared.watchAllGames { return looksLikeFullscreenGame(front) }
        return false
    }

    static func wowIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { isWoW($0) }
    }

    /// The core fix. Safe to call frequently and when no game is running.
    ///
    /// `includeWarp: false` runs only the counter-unwind + re-association —
    /// the parts that are invisible to gameplay. The 1px warp (needed to force
    /// a hardware-cursor repaint) moves the real cursor, so callers on a
    /// periodic timer must not fire it every tick: warping once a second while
    /// someone is aiming in-game reads as input jitter. The warp is also
    /// skipped outright while any mouse button is held (mid-click / drag /
    /// camera turn), when a 1px displacement is most likely to be felt.
    static func restoreBurst(includeWarp: Bool = true) {
        let display = CGMainDisplayID()

        // 1. Unwind a possibly-negative hide counter. CGDisplayShowCursor is
        //    idempotent once the counter hits zero, so extra calls are harmless.
        for _ in 0..<8 { CGDisplayShowCursor(display) }

        // 2. Re-link the mouse to the on-screen cursor (camera grabs unlink it).
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

        guard includeWarp, NSEvent.pressedMouseButtons == 0 else { return }

        // 3. Force a hardware-cursor repaint by nudging 1px and back.
        let loc = currentCursorLocationCG()
        let nudged = CGPoint(x: loc.x + 1, y: loc.y)
        CGWarpMouseCursorPosition(nudged)
        CGWarpMouseCursorPosition(loc)
    }

    /// Whether WindowServer currently reports the cursor as visible. Used by
    /// the safety timer to decide when the disruptive full burst is warranted.
    /// CGCursorIsVisible is marked unavailable to Swift (deprecated 10.9) but
    /// the symbol is still exported by CoreGraphics and still tracks the
    /// hide/show state we care about — so load it dynamically, same pattern as
    /// the SkyLight cursor-scale calls. If the symbol ever disappears, fail
    /// toward "visible" (quiet maintenance only, never spurious warps).
    private typealias CursorVisibleFn = @convention(c) () -> boolean_t
    private static let cursorVisibleFn: CursorVisibleFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let p = dlsym(h, "CGCursorIsVisible") else {
            return nil
        }
        return unsafeBitCast(p, to: CursorVisibleFn.self)
    }()
    static var cursorVisible: Bool {
        guard let fn = cursorVisibleFn else { return true }
        return fn() != 0
    }

    /// Cursor location in CoreGraphics (top-left origin) coordinates.
    private static func currentCursorLocationCG() -> CGPoint {
        let mouse = NSEvent.mouseLocation // bottom-left origin (AppKit)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: mouse.x, y: screenHeight - mouse.y)
    }
}

// MARK: - Global hotkey (⌥⌘C) to force a restore on demand

final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onFire: () -> Void

    init(onFire: @escaping () -> Void) {
        self.onFire = onFire
        install()
    }

    private func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx -> OSStatus in
            guard let ctx else { return noErr }
            let me = Unmanaged<Hotkey>.fromOpaque(ctx).takeUnretainedValue()
            me.onFire()
            _ = event
            return noErr
        }, 1, &spec, selfPtr, &handler)

        let id = EventHotKeyID(signature: OSType(0x4B435552 /* 'KCUR' */), id: 1)
        // ⌥⌘C  →  optionKey + cmdKey, keycode 8 = 'c'
        RegisterEventHotKey(UInt32(kVK_ANSI_C),
                            UInt32(optionKey | cmdKey),
                            id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - Cursor-size slider (custom menu item view)

final class CursorSizeMenuView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Cursor size")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let onChange: (Double) -> Void

    init(value: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 56))

        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 20, y: 32, width: 130, height: 18)
        addSubview(titleLabel)

        valueLabel.font = .menuFont(ofSize: 0)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 150, y: 32, width: 70, height: 18)
        addSubview(valueLabel)

        slider.minValue = 1.0
        slider.maxValue = 4.0
        slider.numberOfTickMarks = 4
        slider.allowsTickMarkValuesOnly = false
        slider.doubleValue = value
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.frame = NSRect(x: 20, y: 8, width: 200, height: 20)
        addSubview(slider)

        updateValueLabel(value)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateValueLabel(_ v: Double) {
        valueLabel.stringValue = String(format: "%.1f×", v)
    }
    @objc private func sliderMoved() {
        let v = slider.doubleValue
        updateValueLabel(v)
        onChange(v)
    }
    func setValue(_ v: Double) {
        slider.doubleValue = v
        updateValueLabel(v)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var safetyTimer: Timer?
    private var hotkey: Hotkey?
    private let settings = Settings.shared

    /// Restores performed this session (visible proof the app is working —
    /// and the live-WoW verification instrument).
    private var restoreCount = 0

    private func noteRestore(flash: Bool = true) {
        restoreCount += 1
        refreshMenuTitle()
        if flash { flashIcon() }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()

        // Fire the burst the instant any app becomes active — this is the
        // alt-tab-back-into-WoW moment.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Pin the cursor size now, and re-pin the instant a display reconfigures
        // (a full-screen game switching display mode is what resets it to 1.0).
        if settings.keepSize { CursorScale.set(Float(settings.cursorScale)) }
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in
            if Settings.shared.keepSize {
                CursorScale.enforce(Float(Settings.shared.cursorScale))
            }
        }, nil)

        // Light safety re-check (catches the in-app alert case where no
        // activation event fires, and any non-display reset of the cursor size).
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.settings.enabled, CursorFixer.frontmostIsTarget() {
                if CursorFixer.cursorVisible {
                    // Cursor is fine: quiet maintenance only (counter unwind +
                    // re-association). No warp — a 1px warp every second while
                    // someone is playing reads as aim jitter.
                    CursorFixer.restoreBurst(includeWarp: false)
                } else {
                    // Cursor actually lost (the in-app-alert case where no
                    // activation event fires): full burst, and count it.
                    CursorFixer.restoreBurst()
                    self.noteRestore(flash: false)
                }
            }
            if self.settings.keepSize {
                CursorScale.enforce(Float(self.settings.cursorScale))
            }
            self.refreshMenuTitle()
        }

        hotkey = Hotkey { [weak self] in
            CursorFixer.restoreBurst()
            self?.noteRestore()
        }
    }

    // MARK: Status item + menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays",
                                   accessibilityDescription: "KeepCursor")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let pauseItem = NSMenuItem(title: settings.enabled ? "Pause" : "Resume",
                                   action: #selector(toggleEnabled),
                                   keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let watchAll = NSMenuItem(title: "Watch all games (not just WoW)",
                                  action: #selector(toggleWatchAll), keyEquivalent: "")
        watchAll.target = self
        watchAll.state = settings.watchAllGames ? .on : .off
        menu.addItem(watchAll)

        let restore = NSMenuItem(title: "Restore cursor now",
                                 action: #selector(restoreNow), keyEquivalent: "c")
        restore.keyEquivalentModifierMask = [.command, .option]
        restore.target = self
        menu.addItem(restore)

        menu.addItem(.separator())

        // Cursor size section
        if CursorScale.available {
            let keepSize = NSMenuItem(title: "Keep cursor size",
                                      action: #selector(toggleKeepSize), keyEquivalent: "")
            keepSize.target = self
            keepSize.state = settings.keepSize ? .on : .off
            menu.addItem(keepSize)

            let sliderItem = NSMenuItem()
            let view = CursorSizeMenuView(value: settings.cursorScale) { [weak self] v in
                guard let self else { return }
                self.settings.cursorScale = v
                if self.settings.keepSize { CursorScale.set(Float(v)) }
            }
            sliderItem.view = view
            menu.addItem(sliderItem)

            menu.addItem(.separator())
        }

        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin),
                               keyEquivalent: "")
        login.target = self
        login.state = loginEnabled() ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let about = NSMenuItem(title: "KeepCursor — batesai.org", action: #selector(openSite),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit KeepCursor", action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func statusLine() -> String {
        if !settings.enabled { return "Paused" }
        let base = CursorFixer.wowIsRunning() ? "Active — WoW running" : "Watching for WoW…"
        return restoreCount > 0 ? "\(base) · restored \(restoreCount)×" : base
    }

    private func refreshMenuTitle() {
        statusItem.menu?.items.first?.title = statusLine()
    }

    // MARK: Actions

    @objc private func appActivated(_ note: Notification) {
        guard settings.enabled else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        let isTarget = CursorFixer.isWoW(app)
            || (settings.watchAllGames && CursorFixer.looksLikeFullscreenGame(app))
        guard isTarget else { return }
        // A short burst sequence covers the WindowServer settling after switch.
        for delay in [0.0, 0.15, 0.4, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                CursorFixer.restoreBurst()
            }
        }
        noteRestore(flash: false) // count the sequence once, not 4×
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        rebuildMenu()
    }
    @objc private func toggleWatchAll() {
        settings.watchAllGames.toggle()
        rebuildMenu()
    }
    @objc private func toggleKeepSize() {
        settings.keepSize.toggle()
        if settings.keepSize { CursorScale.set(Float(settings.cursorScale)) }
        rebuildMenu()
    }
    @objc private func restoreNow() {
        CursorFixer.restoreBurst()
        noteRestore()
    }
    @objc private func openSite() {
        if let url = URL(string: "https://batesai.org") { NSWorkspace.shared.open(url) }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func flashIcon() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "cursorarrow.click.2",
                               accessibilityDescription: "KeepCursor")
        button.image?.isTemplate = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays",
                                                     accessibilityDescription: "KeepCursor")
            self?.statusItem.button?.image?.isTemplate = true
        }
    }

    /// LaunchAgent path is the single source of truth for login state — a
    /// UserDefaults mirror drifts the moment the user deletes the plist.
    private var loginAgentURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents/com.batesai.keep-cursor.plist")
    }
    private func loginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: loginAgentURL.path)
    }
    @objc private func toggleLogin() {
        let enable = !loginEnabled()
        let fm = FileManager.default
        let url = loginAgentURL
        if enable {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.batesai.keep-cursor</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(Bundle.main.bundlePath)/Contents/MacOS/KeepCursor</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
            </dict>
            </plist>
            """
            try? plist.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(at: url)
        }
        rebuildMenu()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
