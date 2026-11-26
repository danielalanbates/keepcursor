// KeepCursor — automatic unlock of a pointer WoW left captured.
// All rights reserved. Copyright (c) 2026 Bates LLC / Daniel Bates.
//
// Proven 2026-11-25: WoW can leave the OS pointer captured while it is in front.
// No Apple API from a helper frees it; WoW's own MouselookStart+MouselookStop
// does. The KeepCursor addon binds that reset to a hidden key (ALT-CTRL-SHIFT-F12)
// and this class presses that key when CapturedPointerDetector sees the capture.

import AppKit
import ApplicationServices
import CoreGraphics

enum KCLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/KeepCursor.log")
    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            try? fm.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

final class CaptureUnlocker {
    static let unlockKeyCode: CGKeyCode = 111 // kVK_F12; addon binds ALT-CTRL-SHIFT-F12
    private(set) var detector = CapturedPointerDetector()
    private var tap: CFMachPort?
    private var fallbackMonitor: Any?
    private var retryTimer: Timer?
    private var frontIsWoW = false
    private var frontPID: pid_t?
    var isEnabled: () -> Bool = { true }
    var onChange: () -> Void = {}

    var accessibilityGranted: Bool { AXIsProcessTrusted() }
    var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }
    var usingEventTap: Bool { tap != nil }

    func start() {
        updateFront(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.updateFront(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        promptOncePerVersion()
        installTap()
        if tap == nil { installFallback() }
        // Grants made later take effect without a relaunch; tick also expires verifies.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.tap == nil, self.inputMonitoringGranted {
                self.installTap()
                if self.tap != nil, let m = self.fallbackMonitor {
                    NSEvent.removeMonitor(m)
                    self.fallbackMonitor = nil
                }
            }
            if self.detector.tick(now: ProcessInfo.processInfo.systemUptime) == .verifyFailed {
                KCLog.write("unlock NOT verified within \(CapturedPointerDetector.verifyWindow)s (pointer still frozen); next cooldown \(Int(self.detector.cooldown))s")
                self.onChange()
            }
        }
        KCLog.write("start v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") accessibility=\(accessibilityGranted) inputMonitoring=\(inputMonitoringGranted) source=\(tap != nil ? "eventTap" : "NSEvent")")
    }

    private func updateFront(_ app: NSRunningApplication?) {
        frontPID = app?.processIdentifier
        frontIsWoW = app.map { $0.bundleIdentifier?.lowercased().hasPrefix("com.blizzard.worldofwarcraft") == true } ?? false
    }

    private func promptOncePerVersion() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let key = "permissionsPromptedFor"
        guard UserDefaults.standard.string(forKey: key) != version else { return }
        UserDefaults.standard.set(version, forKey: key)
        if !accessibilityGranted {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if !inputMonitoringGranted { _ = CGRequestListenEventAccess() }
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<CaptureUnlocker>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                } else {
                    let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
                    let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
                    me.handleMotion(delta: hypot(dx, dy))
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: refcon) else { return }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        KCLog.write("listen-only mouse event tap installed")
    }

    private func installFallback() {
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            self?.handleMotion(delta: hypot(e.deltaX, e.deltaY))
        }
    }

    private func handleMotion(delta: Double) {
        guard isEnabled() else { return }
        let mouse = NSEvent.mouseLocation
        let buttons = NSEvent.pressedMouseButtons != 0
            || CursorFixer.buttonMask(.hidSystemState) != 0
        let atEdge = NSScreen.screens.contains { screen in
            let f = screen.frame
            return f.insetBy(dx: -1, dy: -1).contains(mouse)
                && (abs(mouse.x - f.minX) <= 1 || abs(mouse.x - f.maxX) <= 1
                    || abs(mouse.y - f.minY) <= 1 || abs(mouse.y - f.maxY) <= 1)
        }
        let now = ProcessInfo.processInfo.systemUptime
        switch detector.motion(isTarget: frontIsWoW, buttons: buttons ? 1 : 0,
                               x: Double(mouse.x), y: Double(mouse.y),
                               delta: delta, atScreenEdge: atEdge, now: now) {
        case .fire:
            if pressUnlockKey() {
                KCLog.write("captured pointer detected (WoW frontmost, buttons up, pointer frozen); unlock key sent #\(detector.fired)")
            } else {
                detector.fireNotDelivered()
                KCLog.write("captured pointer detected but unlock key NOT sent (accessibility=\(accessibilityGranted), WoW frontmost=\(frontIsWoW)); next cooldown \(Int(detector.cooldown))s")
            }
            onChange()
        case .freed:
            KCLog.write("pointer moving again: unlock verified (freed \(detector.freed)/\(detector.fired))")
            onChange()
        default:
            break
        }
    }

    /// Presses ALT-CTRL-SHIFT-F12 as real modifier + key events, only while WoW
    /// is still frontmost. Requires Accessibility.
    private func pressUnlockKey() -> Bool {
        guard accessibilityGranted,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier?.lowercased().hasPrefix("com.blizzard.worldofwarcraft") == true,
              let src = CGEventSource(stateID: .hidSystemState) else { return false }
        let mods: [(CGKeyCode, CGEventFlags)] = [(59, .maskControl), (58, .maskAlternate), (56, .maskShift)]
        var flags: CGEventFlags = []
        var events: [CGEvent] = []
        for (key, flag) in mods {
            flags.insert(flag)
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true) else { return false }
            e.type = .flagsChanged
            e.flags = flags
            events.append(e)
        }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: Self.unlockKeyCode, keyDown: down) else { return false }
            e.flags = flags.union(.maskSecondaryFn)
            events.append(e)
        }
        for (key, flag) in mods.reversed() {
            flags.remove(flag)
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return false }
            e.type = .flagsChanged
            e.flags = flags
            events.append(e)
        }
        for e in events {
            e.post(tap: .cghidEventTap)
            usleep(8_000)
        }
        return true
    }

    func statusLine() -> String {
        let ax = accessibilityGranted ? "on" : "NEEDED"
        let im = inputMonitoringGranted ? "on" : "off (fallback)"
        return "Auto-unlock: Accessibility \(ax), Input Monitoring \(im) · freed \(detector.freed)/\(detector.fired)"
    }
}
