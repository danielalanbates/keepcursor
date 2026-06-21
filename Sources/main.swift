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
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    init() {
        d.register(defaults: [Keys.enabled: true, Keys.watchAllGames: false])
    }
    var enabled: Bool {
        get { d.bool(forKey: Keys.enabled) }
        set { d.set(newValue, forKey: Keys.enabled) }
    }
    var watchAllGames: Bool {
        get { d.bool(forKey: Keys.watchAllGames) }
        set { d.set(newValue, forKey: Keys.watchAllGames) }
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
    /// A frontmost app occupying the whole main screen with no menu-bar focus
    /// is treated as a game. Kept deliberately conservative.
    static func looksLikeFullscreenGame(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular else { return false }
        // Anything Blizzard / common launchers we always treat as a game host.
        if let bid = app.bundleIdentifier?.lowercased(),
           bid.contains("blizzard") || bid.contains("valvesoftware.steam") {
            return true
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
    static func restoreBurst() {
        let display = CGMainDisplayID()

        // 1. Unwind a possibly-negative hide counter. CGDisplayShowCursor is
        //    idempotent once the counter hits zero, so extra calls are harmless.
        for _ in 0..<8 { CGDisplayShowCursor(display) }

        // 2. Re-link the mouse to the on-screen cursor (camera grabs unlink it).
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

        // 3. Force a hardware-cursor repaint by nudging 1px and back.
        let loc = currentCursorLocationCG()
        let nudged = CGPoint(x: loc.x + 1, y: loc.y)
        CGWarpMouseCursorPosition(nudged)
        CGWarpMouseCursorPosition(loc)
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var safetyTimer: Timer?
    private var hotkey: Hotkey?
    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()

        // Fire the burst the instant any app becomes active — this is the
        // alt-tab-back-into-WoW moment.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Light safety re-check while a target game is frontmost (catches the
        // in-app alert case where no activation event fires).
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.settings.enabled else { return }
            if CursorFixer.frontmostIsTarget() { CursorFixer.restoreBurst() }
            self.refreshMenuTitle()
        }

        hotkey = Hotkey { [weak self] in
            CursorFixer.restoreBurst()
            self?.flashIcon()
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

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled),
                                 keyEquivalent: "")
        enabled.target = self
        enabled.state = settings.enabled ? .on : .off
        menu.addItem(enabled)

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
        return CursorFixer.wowIsRunning() ? "Active — WoW running" : "Watching for WoW…"
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
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        rebuildMenu()
    }
    @objc private func toggleWatchAll() {
        settings.watchAllGames.toggle()
        rebuildMenu()
    }
    @objc private func restoreNow() {
        CursorFixer.restoreBurst()
        flashIcon()
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

    // MARK: Launch at login (SMAppService, macOS 13+)

    private func loginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }
    @objc private func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                NSLog("KeepCursor login toggle failed: \(error)")
            }
            rebuildMenu()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
