// KeepCursor — keeps the macOS mouse cursor visible in World of Warcraft
// (and other full-screen games) both during gameplay and after Command-Tab / alt-tab.
//
// THE PROBLEMS IN WORLD OF WARCRAFT ON MACOS:
//   1. CAMERA STEERING / BUTTON HOLDS:
//      When holding Right Mouse Button (to steer/turn) or Left Mouse Button (to look),
//      WoW deliberately hides the cursor and calls CGAssociateMouseAndMouseCursorPosition(0).
//      On macOS, releasing the button often fails to restore the cursor due to WindowServer bugs,
//      and during the hold, NSEvent.mouseLocation stays frozen even as the trackpad moves.
//   2. ALT-TAB / WINDOW SWITCHING:
//      Switching out of WoW and back can drive the WindowServer cursor hide counter
//      negative and decouple the mouse association.
//   3. HARDWARE CURSOR REPAINT:
//      The hardware cursor sprite is not repainted until a hardware event nudges it.
//
// THE KEEPCURSOR SOLUTIONS:
//   A. ALWAYS-VISIBLE CURSOR OVERLAY (Active during gameplay):
//      A zero-latency, click-through, floating overlay window at screenSaver level
//      that smoothly tracks the mouse position. In camera-steering/relative mode,
//      physical delta events (deltaX, deltaY) continue to drive the overlay in real-time
//      so the circle NEVER gets stuck in one place.
//   B. INSTANT RESTORE & WARP ON BUTTON / DRAG RELEASE:
//      When steering or dragging ends, warps cursor to the overlay coordinate, unwinds
//      the hide counter, calls CGSForceShowCursor via SkyLight, and re-associates mouse position.
//   C. CONTINUOUS IDLE WATCHDOG:
//      Whenever buttons == 0 (not steering), actively ensures CGAssociateMouseAndMouseCursorPosition(1)
//      and checks CGCursorIsVisible(). If hidden, restores the cursor immediately.
//   D. RESTORE BURST ON APP ACTIVATION:
//      Fires immediately when alt-tabbing back into WoW.
//   E. CURSOR SIZE PINNING (SkyLight CGSSetCursorScale):
//      Prevents WoW's display-mode switches from resetting your cursor size.
//
// Zero special permissions required. Fully self-contained.

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
            Keys.overlayStyle: "ring",
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
        get { d.string(forKey: Keys.overlayStyle) ?? "ring" }
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
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(sym, to: CursorVisibleFn.self)
    }()

    static func isCursorVisible() -> Bool {
        return cursorVisibleFn?() != 0
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

    /// Core cursor restoration.
    /// Safely unhides WindowServer cursor, re-links mouse, and nudges 1px to repaint.
    static func restoreBurst(includeWarp: Bool = true) {
        // 1. Force WindowServer to show cursor
        SkyLightCursor.forceShow()

        // 2. Unwind negative hide counter on the display
        let display = CGMainDisplayID()
        for _ in 0..<8 { CGDisplayShowCursor(display) }

        // 3. Re-associate mouse and cursor position
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

        guard includeWarp, NSEvent.pressedMouseButtons == 0 else { return }

        // 4. Force hardware cursor repaint by nudging 1px and back
        let loc = currentCursorLocationCG()
        let nudged = CGPoint(x: loc.x + 1, y: loc.y)
        CGWarpMouseCursorPosition(nudged)
        CGWarpMouseCursorPosition(loc)
    }

    /// Cursor location in CoreGraphics (top-left origin) coordinates.
    static func currentCursorLocationCG() -> CGPoint {
        let mouse = NSEvent.mouseLocation // bottom-left origin
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: mouse.x, y: screenHeight - mouse.y)
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

        overlayView.style = Settings.shared.overlayStyle
        overlayView.colorName = Settings.shared.overlayColor
        if overlayView.isPressed != isPressed {
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

    private var lastButtons: Int = 0
    private var restoreCount = 0

    // Virtual cursor position that tracks trackpad deltas even during mouselook / relative mode
    private var virtualPos: CGPoint = .zero
    private var lastMouseLoc: CGPoint = .zero
    private var globalMouseMonitor: Any?

    private func noteRestore(flash: Bool = true) {
        restoreCount += 1
        refreshMenuTitle()
        if flash { flashIcon() }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()

        virtualPos = NSEvent.mouseLocation
        lastMouseLoc = virtualPos

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

        // 3. Global Mouse Event Monitor:
        //    Tracks physical trackpad/mouse delta events even when WoW disassociates
        //    mouse position (CGAssociateMouseAndMouseCursorPosition(0)).
        //    Ensures the circle overlay follows the user's hand, and restores the cursor
        //    immediately on release.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseUp,
            .rightMouseUp,
            .otherMouseUp
        ]) { [weak self] event in
            self?.handleGlobalMouseEvent(event)
        }

        // 4. Fast 60Hz gameplay loop:
        //    - Smoothly positions the Always-Visible Overlay
        //    - Enforces cursor association and visibility watchdog
        //    - Detects button release transitions in real time
        gameLoopTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.gameTick()
        }

        hotkey = Hotkey { [weak self] in
            CursorFixer.restoreBurst(includeWarp: true)
            self?.noteRestore()
        }
    }

    private func handleGlobalMouseEvent(_ event: NSEvent) {
        guard settings.enabled else { return }
        let isTarget = CursorFixer.frontmostIsTarget()
        guard isTarget else { return }

        let currentMouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 2560, height: 1600)

        // If system mouseLocation is moving normally, keep virtualPos locked to it
        if currentMouse != lastMouseLoc {
            virtualPos = currentMouse
            lastMouseLoc = currentMouse
        } else if event.deltaX != 0 || event.deltaY != 0 {
            // System mouse is stationary / disassociated by WoW (camera turn/steering)!
            // Accumulate physical trackpad deltas so the circle tracks the user's trackpad movement
            virtualPos.x += event.deltaX
            virtualPos.y -= event.deltaY // Cocoa Y is inverted vs screen deltas
            virtualPos.x = max(0, min(screen.width, virtualPos.x))
            virtualPos.y = max(0, min(screen.height, virtualPos.y))
        }

        // Detect any mouse button release
        if event.type == .leftMouseUp || event.type == .rightMouseUp || event.type == .otherMouseUp {
            // Button released! Warp hardware cursor to where the user aimed the circle
            let cgY = screen.height - virtualPos.y
            CGWarpMouseCursorPosition(CGPoint(x: virtualPos.x, y: cgY))
            CursorFixer.restoreBurst(includeWarp: false)
            noteRestore(flash: false)
        }

        if settings.alwaysVisibleOverlay {
            CursorOverlayController.shared.update(
                mouseLocation: virtualPos,
                isPressed: NSEvent.pressedMouseButtons != 0,
                shouldShow: true
            )
        }
    }

    private func gameTick() {
        guard settings.enabled else {
            CursorOverlayController.shared.hide()
            return
        }

        let isTarget = CursorFixer.frontmostIsTarget()
        let mouse = NSEvent.mouseLocation
        let buttons = NSEvent.pressedMouseButtons

        if isTarget {
            let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 2560, height: 1600)

            // Sync with hardware position if it changed
            if mouse != lastMouseLoc {
                virtualPos = mouse
                lastMouseLoc = mouse
            }

            // Update the Always-Visible Cursor Overlay
            let showOverlay = settings.alwaysVisibleOverlay
            CursorOverlayController.shared.update(
                mouseLocation: virtualPos,
                isPressed: buttons != 0,
                shouldShow: showOverlay
            )

            // Detect mouse button release transition
            if lastButtons != 0 && buttons == 0 {
                let cgY = screen.height - virtualPos.y
                CGWarpMouseCursorPosition(CGPoint(x: virtualPos.x, y: cgY))
                CursorFixer.restoreBurst(includeWarp: false)
                noteRestore(flash: false)
            }

            // IDLE WATCHDOG: When no buttons are held (idle navigation / moving trackpad without click)
            if buttons == 0 {
                // Ensure mouse position is NEVER disassociated while idle
                CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

                // If hardware cursor is hidden by WoW, restore it immediately
                if !CursorFixer.isCursorVisible() {
                    CursorFixer.restoreBurst(includeWarp: false)
                }
            }

            if settings.keepSize {
                SkyLightCursor.enforceScale(Float(settings.cursorScale))
            }
        } else {
            CursorOverlayController.shared.hide()
        }

        lastButtons = buttons
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

    private func returnFocusToGame() {
        guard let game = CursorFixer.targetApp() else { return }
        game.activate(options: [])
        for delay in [0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                CursorFixer.restoreBurst(includeWarp: true)
            }
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
            ("ring", "Combat Reticle (WoW Style - Recommended)"),
            ("arrow", "Classic Pointer"),
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
        guard settings.enabled else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        let isTarget = CursorFixer.isWoW(app)
            || (settings.watchAllGames && CursorFixer.looksLikeFullscreenGame(app))
        guard isTarget else { return }

        for delay in [0.0, 0.15, 0.4, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                CursorFixer.restoreBurst(includeWarp: true)
            }
        }
        noteRestore(flash: false)
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
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
        CursorFixer.restoreBurst(includeWarp: true)
        noteRestore()
        returnFocusToGame()
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
