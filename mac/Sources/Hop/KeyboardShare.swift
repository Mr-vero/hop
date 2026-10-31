import AppKit
import ApplicationServices

/// Universal Control for the phone: push the pointer off the right edge of the Mac's screen and the Mac's
/// trackpad and keyboard drive the phone (it sees a normal USB-style keyboard and mouse). Push back off
/// the phone's left edge, or press ⌘⎋, to return.
///
/// While on the phone, an event tap swallows the Mac's input and forwards it. Anything going wrong
/// (connection lost, tap disabled, phone moving away) hands input straight back to the Mac.
@MainActor
final class KeyboardShare {
    private static let keyboardID: UInt16 = 1
    private static let mouseID: UInt16 = 2

    var onChange: () -> Void = {}
    private(set) var onPhone = false
    private(set) var ready = false
    private var stream: PhoneStream?
    private var edgeMonitors: [Any] = []
    private var edgePush: CGFloat = 0
    private var lastEdgePush = Date.distantPast
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    // Phone-side state
    private var buttons: UInt8 = 0
    private var modifiers: UInt8 = 0
    private var keys: [UInt8] = []
    /** Rough guess of the phone pointer's distance from the phone's left edge, to know when to come back. */
    private var phoneX: CGFloat = 0
    private var backPush: CGFloat = 0

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /** Shows macOS's prompt to let Hop control input (needed to move the keyboard and mouse to the phone). */
    static func askPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    var isRunning: Bool { stream != nil }

    func start(stream: PhoneStream) {
        stop()
        self.stream = stream
        stream.onReady = { [weak self, weak stream] in
            guard let self, let stream, self.stream === stream else { return }
            stream.uhidCreate(id: Self.keyboardID, name: "Hop keyboard", descriptor: HID.keyboardDescriptor)
            stream.uhidCreate(id: Self.mouseID, name: "Hop mouse", descriptor: HID.mouseDescriptor)
            self.ready = true
            self.onChange()
        }
        stream.onEnded = { [weak self, weak stream] _ in
            guard let self, self.stream === stream else { return }
            self.stop()
        }
        stream.start()
        watchEdge()
    }

    func stop() {
        leavePhone()
        edgeMonitors.forEach(NSEvent.removeMonitor)
        edgeMonitors = []
        if let stream {
            self.stream = nil
            if ready { stream.uhidDestroy(id: Self.keyboardID); stream.uhidDestroy(id: Self.mouseID) }
            // Give the destroy messages a moment to go out before closing
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { stream.stop() }
        }
        ready = false
        onChange()
    }

    // MARK: crossing over

    private func watchEdge() {
        let handler: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMovedOnMac(e) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: handler) { edgeMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { handler($0); return $0 }) { edgeMonitors.append(m) }
    }

    private func mouseMovedOnMac(_ e: NSEvent) {
        guard ready, !onPhone, Self.hasPermission else { return }
        // The phone sits to the right of the right-most screen
        let rightEdge = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        let p = NSEvent.mouseLocation
        guard p.x >= rightEdge - 1, e.deltaX > 0 else { edgePush = 0; return }
        // Require a deliberate push against the edge, like Universal Control
        if Date().timeIntervalSince(lastEdgePush) > 0.4 { edgePush = 0 }
        lastEdgePush = Date()
        edgePush += e.deltaX
        if edgePush > 40 { enterPhone() }
    }

    private func enterPhone() {
        guard let stream, ready, !onPhone else { return }
        let mask: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                   .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
                                   .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let events = mask.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: events, callback: tapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // Freeze the Mac pointer at the edge; its movement now drives the phone's pointer
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayHideCursor(CGMainDisplayID())
        onPhone = true
        buttons = 0; keys = []; modifiers = 0
        phoneX = 0; backPush = 0
        _ = stream
        onChange()
    }

    private func leavePhone() {
        guard onPhone else { return }
        onPhone = false
        // Let go of anything still held on the phone
        buttons = 0; keys = []; modifiers = 0
        sendMouse(dx: 0, dy: 0)
        sendKeys()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
        // Put the pointer just inside the edge so it doesn't cross straight back
        let rightEdge = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        if let y = CGEvent(source: nil)?.location.y { CGWarpMouseCursorPosition(CGPoint(x: rightEdge - 30, y: y)) }
        edgePush = 0
        onChange()
    }

    // MARK: forwarding (called from the event tap, on the main run loop)

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switched the tap off; turn it back on rather than leaving input half-captured
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = CGFloat(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = CGFloat(event.getIntegerValueField(.mouseEventDeltaY))
            phoneX = min(1500, max(0, phoneX + dx)) // about a phone's width in pointer units
            if phoneX == 0, dx < 0 {
                backPush -= dx
                if backPush > 60 { leavePhone(); return true }
            } else if dx > 0 { backPush = 0 }
            sendMouse(dx: dx, dy: dy)
        case .leftMouseDown, .leftMouseUp: setButton(0x01, type == .leftMouseDown)
        case .rightMouseDown, .rightMouseUp: setButton(0x02, type == .rightMouseDown)
        case .otherMouseDown, .otherMouseUp: setButton(0x04, type == .otherMouseDown)
        case .scrollWheel:
            let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let side = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            if lines != 0 || side != 0 {
                stream?.uhidInput(id: Self.mouseID, report: [buttons, 0, 0, HID.clamp(lines), HID.clamp(-side)])
            }
        case .keyDown, .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            // ⌘⎋ always brings input back to the Mac
            if type == .keyDown, code == 0x35, event.flags.contains(.maskCommand) { leavePhone(); return true }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true } // the phone repeats held keys itself
            guard let usage = HID.usage[code] else { return true }
            if type == .keyDown { if !keys.contains(usage), keys.count < 6 { keys.append(usage) } } else { keys.removeAll { $0 == usage } }
            sendKeys()
        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if code == 0x39 { // Caps Lock: tap it on the phone
                keys.append(0x39); sendKeys(); keys.removeAll { $0 == 0x39 }; sendKeys()
                return true
            }
            modifiers = HID.modifiers(event.flags)
            sendKeys()
        default:
            return false
        }
        return true
    }

    private func setButton(_ bit: UInt8, _ down: Bool) {
        buttons = down ? buttons | bit : buttons & ~bit
        sendMouse(dx: 0, dy: 0)
    }

    private func sendMouse(dx: CGFloat, dy: CGFloat) {
        guard let stream else { return }
        // Reports carry at most ±127 per axis; split big jumps
        var x = Int(dx), y = Int(dy)
        repeat {
            let sx = max(-127, min(127, x)), sy = max(-127, min(127, y))
            stream.uhidInput(id: Self.mouseID, report: [buttons, UInt8(bitPattern: Int8(sx)), UInt8(bitPattern: Int8(sy)), 0, 0])
            x -= sx; y -= sy
        } while x != 0 || y != 0
    }

    private func sendKeys() {
        stream?.uhidInput(id: Self.keyboardID, report: [modifiers, 0] + keys + Array(repeating: 0, count: 6 - keys.count))
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let share = Unmanaged<KeyboardShare>.fromOpaque(refcon).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { share.handle(type, event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// HID report descriptors (the same boot-style keyboard and 5-button wheel mouse scrcpy uses) and key mapping.
enum HID {
    static let keyboardDescriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x75, 0x08, 0x95, 0x01, 0x81, 0x01, 0x05, 0x08, 0x19, 0x01,
        0x29, 0x05, 0x75, 0x01, 0x95, 0x05, 0x91, 0x02, 0x75, 0x03, 0x95, 0x01, 0x91, 0x01, 0x05, 0x07,
        0x19, 0x00, 0x29, 0x65, 0x15, 0x00, 0x25, 0x65, 0x75, 0x08, 0x95, 0x06, 0x81, 0x00, 0xC0,
    ]
    static let mouseDescriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x05,
        0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x03, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03,
        0x81, 0x06, 0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81,
        0x06, 0xC0, 0xC0,
    ]

    static func clamp(_ v: Int64) -> UInt8 { UInt8(bitPattern: Int8(max(-127, min(127, v)))) }

    /// Modifier byte from the Mac's left/right-specific flag bits.
    static func modifiers(_ flags: CGEventFlags) -> UInt8 {
        let raw = flags.rawValue
        var m: UInt8 = 0
        if raw & 0x0001 != 0 { m |= 0x01 } // left control
        if raw & 0x0002 != 0 { m |= 0x02 } // left shift
        if raw & 0x0020 != 0 { m |= 0x04 } // left option
        if raw & 0x0008 != 0 { m |= 0x08 } // left command
        if raw & 0x2000 != 0 { m |= 0x10 } // right control
        if raw & 0x0004 != 0 { m |= 0x20 } // right shift
        if raw & 0x0040 != 0 { m |= 0x40 } // right option
        if raw & 0x0010 != 0 { m |= 0x80 } // right command
        return m
    }

    /// Mac virtual key code → USB HID usage.
    static let usage: [UInt16: UInt8] = [
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A, 0x04: 0x0B,
        0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13,
        0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, 0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B,
        0x10: 0x1C, 0x06: 0x1D,
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25,
        0x19: 0x26, 0x1D: 0x27,
        0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C, 0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F,
        0x1E: 0x30, 0x2A: 0x31, 0x29: 0x33, 0x27: 0x34, 0x32: 0x35, 0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38,
        0x0A: 0x64,
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40, 0x64: 0x41,
        0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45,
        0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x77: 0x4D, 0x79: 0x4E,
        0x7C: 0x4F, 0x7B: 0x50, 0x7D: 0x51, 0x7E: 0x52,
    ]
}
