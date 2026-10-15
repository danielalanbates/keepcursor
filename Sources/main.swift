// KeepCursor — cursor visibility recovery without changing game mouse input.
// All rights reserved. Copyright (c) 2026 Bates LLC / Daniel Bates.
//
// WoW owns relative mouse capture, button state, and cursor position. KeepCursor
// only restores visibility after mouse buttons have settled, and displays a
// click-through fallback at the real cursor position. It never moves the cursor
// or reconnects the mouse while a game may be using relative input.

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
    static let alwaysVisibleOverlay = "alwaysVisibleOverlay"
    static let overlayStyle = "overlayStyle" // "ring", "arrow", "dot"
    static let overlayColor = "overlayColor" // "gold", "cyan", "green", "white"
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    init() {
        d.register(defaults: [
            Keys.enabled: true,
            Keys.watchAllGames: false,
            Keys.keepSize: true,
            Keys.cursorScale: 2.0,
            Keys.alwaysVisibleOverlay: true,
            Keys.overlayStyle: "arrow",
            Keys.overlayColor: "gold",
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
    var keepSize: Bool {
        get { d.bool(forKey: Keys.keepSize) }
        set { d.set(newValue, forKey: Keys.keepSize) }
    }
    var cursorScale: Double {
        get { min(4.0, max(1.0, d.double(forKey: Keys.cursorScale))) }
        set { d.set(min(4.0, max(1.0, newValue)), forKey: Keys.cursorScale) }
    }
    var alwaysVisibleOverlay: Bool {
        get { d.bool(forKey: Keys.alwaysVisibleOverlay) }
        set { d.set(newValue, forKey: Keys.alwaysVisibleOverlay) }
    }
    var overlayStyle: String {
        get { d.string(forKey: Keys.overlayStyle) ?? "arrow" }
        set { d.set(newValue, forKey: Keys.overlayStyle) }
    }
    var overlayColor: String {
        get { d.string(forKey: Keys.overlayColor) ?? "gold" }
        set { d.set(newValue, forKey: Keys.overlayColor) }
    }
}

// MARK: - SkyLight Private APIs (WindowServer cursor control)

enum SkyLightCursor {
    typealias ConnID = UInt32
    private typealias MainConnFn = @convention(c) () -> ConnID
    private typealias ForceShowFn = @convention(c) (ConnID) -> Int32
    private typealias ShowFn = @convention(c) (ConnID) -> Int32
    private typealias GetScaleFn = @convention(c) (ConnID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetScaleFn = @convention(c) (ConnID, Float) -> Int32
    private typealias GetLocationFn = @convention(c) (ConnID, UnsafeMutablePointer<CGPoint>) -> Int32

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func sym<T>(_ name: String) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let mainConn: MainConnFn? = sym("CGSMainConnectionID") ?? sym("SLSMainConnectionID")
    private static let forceShowFn: ForceShowFn? = sym("CGSForceShowCursor") ?? sym("SLSForceShowCursor")
    private static let showFn: ShowFn? = sym("CGSShowCursor") ?? sym("SLSShowCursor")
    private static let getScaleFn: GetScaleFn? = sym("CGSGetCursorScale")
    private static let setScaleFn: SetScaleFn? = sym("CGSSetCursorScale")
    private static let getLocationFn: GetLocationFn? = sym("CGSGetCurrentCursorLocation") ?? sym("SLSGetCurrentCursorLocation")

    static var connectionID: ConnID {
        mainConn?() ?? 0
    }

    static func forceShow() {
        guard let fn = forceShowFn else { return }
        let cid = connectionID
        guard cid != 0 else { return }
        _ = fn(cid)
        if let s = showFn { _ = s(cid) }
    }

    static func currentScale() -> Float? {
        guard let g = getScaleFn else { return nil }
        let cid = connectionID
        guard cid != 0 else { return nil }
        var s: Float = -1
        return g(cid, &s) == 0 ? s : nil
    }

    static func setScale(_ value: Float) {
        guard let st = setScaleFn else { return }
        let cid = connectionID
        guard cid != 0 else { return }
        _ = st(cid, max(1.0, min(4.0, value)))
    }

    static func enforceScale(_ target: Float) {
        guard let cur = currentScale() else { setScale(target); return }
        if abs(cur - target) > 0.01 { setScale(target) }
    }

    static func cursorLocation() -> CGPoint? {
        guard let fn = getLocationFn else { return nil }
        let cid = connectionID
        guard cid != 0 else { return nil }
        var pt = CGPoint.zero
        return fn(cid, &pt) == 0 ? pt : nil
    }
}

// MARK: - Target Game Detection & Restoration

enum CursorFixer {
    private typealias CursorVisibleFn = @convention(c) () -> boolean_t
    private static let cursorVisibleFn: CursorVisibleFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(symbol, to: CursorVisibleFn.self)
    }()

    static func isCursorVisible() -> Bool {
        // If the private visibility query disappears, avoid repeated forced repairs.
        guard let cursorVisibleFn else { return true }
        return cursorVisibleFn() != 0
    }

    static func isWoW(_ app: NSRunningApplication) -> Bool {
        if let bid = app.bundleIdentifier?.lowercased() {
            if bid.contains("worldofwarcraft") || bid.contains("blizzard.wow") {
                return true
            }
        }
        if let name = app.localizedName?.lowercased() {
            if name == "wow" || name.contains("world of warcraft") {
                return true
            }
        }
        if let exe = app.executableURL?.lastPathComponent.lowercased() {
            if exe == "wow" || exe.contains("world of warcraft") {
                return true
            }
        }
        return false
    }

    static func looksLikeFullscreenGame(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular else { return false }
        if let bid = app.bundleIdentifier?.lowercased(),
           bid.contains("blizzard") || bid.contains("valvesoftware.steam") {
            return true
        }
        return ownsFullscreenWindow(pid: app.processIdentifier)
    }

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

    static func targetApp() -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if let wow = apps.first(where: { isWoW($0) }) { return wow }
        if Settings.shared.watchAllGames {
            return apps.first(where: { looksLikeFullscreenGame($0) })
        }
        return nil
    }

    /// Restore visibility only. WoW retains ownership of mouse capture and position.
    /// Recheck live input here as well as in the polling policy: delayed requests
    /// may run after the user starts a camera turn or switches to another app.
    @discardableResult
    static func restoreVisibility() -> Bool {
        guard frontmostIsTarget(), NSEvent.pressedMouseButtons == 0 else { return false }
        SkyLightCursor.forceShow()
        let display = CGMainDisplayID()
        for _ in 0..<8 { CGDisplayShowCursor(display) }
        return true
    }

}

// MARK: - Always-Visible Cursor Overlay View & Window

final class CursorOverlayView: NSView {
    var style: String = "ring"
    var colorName: String = "gold"
    var isPressed: Bool = false

    private var accentColor: NSColor {
        switch colorName.lowercased() {
        case "cyan":  return NSColor(calibratedRed: 0.0, green: 0.9, blue: 1.0, alpha: 0.95)
        case "green": return NSColor(calibratedRed: 0.2, green: 1.0, blue: 0.3, alpha: 0.95)
        case "white": return NSColor(calibratedWhite: 1.0, alpha: 0.95)
        default:      return NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.1, alpha: 0.95) // Gold
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let b = bounds
        let mid = CGPoint(x: b.midX, y: b.midY)
        let color = accentColor

        switch style {
        case "arrow":
            // Draw a crisp, high-visibility gaming arrow pointer
            let path = CGMutablePath()
            let origin = CGPoint(x: 4, y: b.height - 4)
            path.move(to: origin)
            path.addLine(to: CGPoint(x: origin.x, y: origin.y - 24))
            path.addLine(to: CGPoint(x: origin.x + 6, y: origin.y - 18))
            path.addLine(to: CGPoint(x: origin.x + 12, y: origin.y - 25))
            path.addLine(to: CGPoint(x: origin.x + 15, y: origin.y - 22))
            path.addLine(to: CGPoint(x: origin.x + 9, y: origin.y - 15))
            path.addLine(to: CGPoint(x: origin.x + 17, y: origin.y - 15))
            path.closeSubpath()

            // Outer dark drop shadow
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 1, height: -2), blur: 3, color: NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()

            // Inner fill
            ctx.setFillColor(color.cgColor)
            ctx.addPath(path)
            ctx.fillPath()

            // Crisp stroke
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.addPath(path)
            ctx.strokePath()

        case "dot":
            // High-visibility illuminated center dot
            let r: CGFloat = isPressed ? 6.0 : 4.5
            let dotRect = CGRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2)

            // Glow shadow
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 4, color: color.cgColor)
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: dotRect)
            ctx.restoreGState()

            // Center bright core
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: mid.x - 2, y: mid.y - 2, width: 4, height: 4))

        default: // "ring" (Combat Reticle - #1 choice for WoW players)
            let r: CGFloat = isPressed ? 14.0 : 12.0

            // 1. Dark outer drop-shadow
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.8).cgColor)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(4.0)
            ctx.strokeEllipse(in: CGRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2))
            ctx.restoreGState()

            // 2. Bright colored reticle ring
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(isPressed ? 3.0 : 2.0)
            ctx.strokeEllipse(in: CGRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2))

            // 3. Subtle tick crosshairs
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.5)
            let tickLen: CGFloat = 4.0
            // Top
            ctx.move(to: CGPoint(x: mid.x, y: mid.y + r - tickLen))
            ctx.addLine(to: CGPoint(x: mid.x, y: mid.y + r + 2))
            // Bottom
            ctx.move(to: CGPoint(x: mid.x, y: mid.y - r + tickLen))
            ctx.addLine(to: CGPoint(x: mid.x, y: mid.y - r - 2))
            // Left
            ctx.move(to: CGPoint(x: mid.x - r + tickLen, y: mid.y))
            ctx.addLine(to: CGPoint(x: mid.x - r - 2, y: mid.y))
            // Right
            ctx.move(to: CGPoint(x: mid.x + r - tickLen, y: mid.y))
            ctx.addLine(to: CGPoint(x: mid.x + r + 2, y: mid.y))
            ctx.strokePath()

            // 4. Center hotspot dot
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: mid.x - 2, y: mid.y - 2, width: 4, height: 4))
        }
    }
}

final class CursorOverlayController {
    static let shared = CursorOverlayController()

    private let panel: NSPanel
    private let overlayView: CursorOverlayView
    private let windowSize: CGFloat = 48.0
    private var isVisible: Bool = false

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: windowSize, height: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false

        overlayView = CursorOverlayView(frame: panel.contentView?.bounds ?? .zero)
        overlayView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(overlayView)
    }

    func update(mouseLocation: CGPoint, isPressed: Bool, shouldShow: Bool) {
        guard shouldShow else {
            if isVisible {
                panel.orderOut(nil)
                isVisible = false
            }
            return
        }

        let style = Settings.shared.overlayStyle
        let color = Settings.shared.overlayColor
        if overlayView.style != style || overlayView.colorName != color
            || overlayView.isPressed != isPressed {
            overlayView.style = style
            overlayView.colorName = color
            overlayView.isPressed = isPressed
            overlayView.needsDisplay = true
        }

        // Position window centered on mouse coordinate
        let origin: CGPoint
        if Settings.shared.overlayStyle == "arrow" {
            // Arrow hotspot is at top-left
            origin = CGPoint(x: mouseLocation.x - 4, y: mouseLocation.y - windowSize + 4)
        } else {
            // Ring / dot hotspot is at exact center
            origin = CGPoint(x: mouseLocation.x - windowSize / 2, y: mouseLocation.y - windowSize / 2)
        }

        panel.setFrameOrigin(origin)

        if !isVisible {
            panel.orderFrontRegardless()
            isVisible = true
        }
    }

    func hide() {
        if isVisible {
            panel.orderOut(nil)
            isVisible = false
        }
    }
}

// MARK: - Global Hotkey (⌥⌘C)

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
        RegisterEventHotKey(UInt32(kVK_ANSI_C),
                            UInt32(optionKey | cmdKey),
                            id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - Cursor-size slider View

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

// MARK: - Application Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private var gameLoopTimer: Timer?
    private var hotkey: Hotkey?
    private let settings = Settings.shared

    private var recovery = CursorRecoveryPolicy()
    private var restoreCount = 0
    private var activationGeneration = 0

    private func noteRestore(flash: Bool = true) {
        restoreCount += 1
        refreshMenuTitle()
        if flash { flashIcon() }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()

        // 1. App-activation notification: instant burst on Cmd-Tab back to WoW
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // 2. Pin cursor size on launch and upon display reconfigurations
        if settings.keepSize { SkyLightCursor.setScale(Float(settings.cursorScale)) }
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in
            if Settings.shared.keepSize {
                SkyLightCursor.enforceScale(Float(Settings.shared.cursorScale))
            }
        }, nil)

        // The timer observes mouse position/buttons; it never posts input events.
        gameLoopTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.gameTick()
        }

        hotkey = Hotkey { [weak self] in
            self?.attemptRestore(manual: true)
        }
    }

    private func attemptRestore(manual: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let buttons = NSEvent.pressedMouseButtons
        recovery.observe(buttons: buttons, now: now)
        if recovery.attemptRestore(
            enabled: settings.enabled,
            isTarget: CursorFixer.frontmostIsTarget(),
            buttons: buttons,
            cursorVisible: CursorFixer.isCursorVisible(),
            now: now,
            manual: manual,
            restore: { CursorFixer.restoreVisibility() }
        ) {
            noteRestore(flash: manual)
        }
    }

    private func gameTick() {
        let isTarget = CursorFixer.frontmostIsTarget()
        let buttons = NSEvent.pressedMouseButtons
        recovery.observe(buttons: buttons, now: ProcessInfo.processInfo.systemUptime)

        // Show the fallback at the actual click location. A separate virtual
        // pointer would imply clicks land somewhere WoW cannot receive them.
        CursorOverlayController.shared.update(
            mouseLocation: NSEvent.mouseLocation,
            isPressed: false,
            shouldShow: CursorRecoveryPolicy.shouldShowOverlay(
                enabled: settings.enabled,
                isTarget: isTarget,
                overlayEnabled: settings.alwaysVisibleOverlay,
                buttons: buttons
            )
        )

        guard settings.enabled, isTarget else { return }
        // Repair a missing native cursor only after release has settled. Visibility
        // repairs are limited to once per second, without association or warps.
        attemptRestore()
        if settings.keepSize, buttons == 0 {
            SkyLightCursor.enforceScale(Float(settings.cursorScale))
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays",
                                   accessibilityDescription: "KeepCursor")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        rebuildMenu()
    }

    @objc private func statusItemClicked() {
        let isRight = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRight {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            restoreNow()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        defer { self.menu = menu }

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let pauseItem = NSMenuItem(title: settings.enabled ? "Pause KeepCursor" : "Resume KeepCursor",
                                   action: #selector(toggleEnabled),
                                   keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        // Always-Visible Cursor Overlay Toggle
        let overlayItem = NSMenuItem(title: "Always-Visible Cursor in WoW",
                                     action: #selector(toggleOverlay),
                                     keyEquivalent: "")
        overlayItem.target = self
        overlayItem.state = settings.alwaysVisibleOverlay ? .on : .off
        menu.addItem(overlayItem)

        // Overlay Style Submenu
        let styleMenu = NSMenu()
        let styles: [(id: String, name: String)] = [
            ("ring", "Combat Reticle"),
            ("arrow", "Classic Pointer (Recommended)"),
            ("dot", "Precision Dot")
        ]
        for s in styles {
            let item = NSMenuItem(title: s.name, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            item.state = (settings.overlayStyle == s.id) ? .on : .off
            styleMenu.addItem(item)
        }
        let styleParent = NSMenuItem(title: "Cursor Overlay Style", action: nil, keyEquivalent: "")
        styleParent.submenu = styleMenu
        menu.addItem(styleParent)

        // Overlay Color Submenu
        let colorMenu = NSMenu()
        let colors: [(id: String, name: String)] = [
            ("gold", "Gold / Amber"),
            ("cyan", "Neon Cyan"),
            ("green", "Fel Green"),
            ("white", "Crisp White")
        ]
        for c in colors {
            let item = NSMenuItem(title: c.name, action: #selector(selectColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.id
            item.state = (settings.overlayColor == c.id) ? .on : .off
            colorMenu.addItem(item)
        }
        let colorParent = NSMenuItem(title: "Cursor Color", action: nil, keyEquivalent: "")
        colorParent.submenu = colorMenu
        menu.addItem(colorParent)

        let watchAll = NSMenuItem(title: "Watch all games (not just WoW)",
                                  action: #selector(toggleWatchAll), keyEquivalent: "")
        watchAll.target = self
        watchAll.state = settings.watchAllGames ? .on : .off
        menu.addItem(watchAll)

        let restore = NSMenuItem(title: "Restore cursor now (or left-click icon)",
                                 action: #selector(restoreNow), keyEquivalent: "c")
        restore.keyEquivalentModifierMask = [.command, .option]
        restore.target = self
        menu.addItem(restore)

        menu.addItem(.separator())

        // Cursor size section
        let keepSize = NSMenuItem(title: "Keep cursor size",
                                  action: #selector(toggleKeepSize), keyEquivalent: "")
        keepSize.target = self
        keepSize.state = settings.keepSize ? .on : .off
        menu.addItem(keepSize)

        let sliderItem = NSMenuItem()
        let view = CursorSizeMenuView(value: settings.cursorScale) { [weak self] v in
            guard let self else { return }
            self.settings.cursorScale = v
            if self.settings.keepSize { SkyLightCursor.setScale(Float(v)) }
        }
        sliderItem.view = view
        menu.addItem(sliderItem)

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
    }

    private func statusLine() -> String {
        if !settings.enabled { return "Paused" }
        let base = CursorFixer.wowIsRunning() ? "Active — WoW running" : "Watching for WoW…"
        return restoreCount > 0 ? "\(base) · restored \(restoreCount)×" : base
    }

    private func refreshMenuTitle() {
        menu.items.first?.title = statusLine()
    }

    // MARK: Actions

    @objc private func appActivated(_ note: Notification) {
        activationGeneration += 1
        recovery.reset()
        CursorOverlayController.shared.hide()
        guard settings.enabled,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              CursorFixer.isWoW(app)
                || (settings.watchAllGames && CursorFixer.looksLikeFullscreenGame(app)) else { return }

        let generation = activationGeneration
        let targetPID = app.processIdentifier
        for delay in [0.3, 0.6, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.activationGeneration == generation,
                      self.settings.enabled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return }
                self.attemptRestore()
            }
        }
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        activationGeneration += 1
        recovery.reset()
        if !settings.enabled { CursorOverlayController.shared.hide() }
        rebuildMenu()
    }

    @objc private func toggleOverlay() {
        settings.alwaysVisibleOverlay.toggle()
        rebuildMenu()
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String {
            settings.overlayStyle = s
            rebuildMenu()
        }
    }

    @objc private func selectColor(_ sender: NSMenuItem) {
        if let c = sender.representedObject as? String {
            settings.overlayColor = c
            rebuildMenu()
        }
    }

    @objc private func toggleWatchAll() {
        settings.watchAllGames.toggle()
        rebuildMenu()
    }

    @objc private func toggleKeepSize() {
        settings.keepSize.toggle()
        if settings.keepSize { SkyLightCursor.setScale(Float(settings.cursorScale)) }
        rebuildMenu()
    }

    @objc private func restoreNow() {
        attemptRestore(manual: true)
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
