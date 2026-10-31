import AppKit
import AVFoundation
import QuartzCore

/// Either a borderless window drawn as a Galaxy S25 Ultra-style phone (titanium frame, thin black bezel,
/// camera hole and working side buttons; drag the frame to move it), or in dock mode an ordinary,
/// resizable Mac window showing the phone's separate desktop display, which can go full screen.
@MainActor
final class PhoneWindow: NSWindow {
    private let frameView: PhoneFrameView
    private let stream: PhoneStream
    let isDock: Bool
    var onClose: () -> Void = {}
    private var darkenedOnce = false
    private var dockAspect: CGFloat = 0

    init(stream: PhoneStream, title: String, dock: Bool = false) {
        self.stream = stream
        isDock = dock
        frameView = PhoneFrameView(stream: stream, bezel: !dock)
        let style: NSWindow.StyleMask = dock ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless]
        super.init(contentRect: NSRect(x: 0, y: 0, width: dock ? 1280 : 400, height: dock ? 800 : 860), styleMask: style, backing: .buffered, defer: false)
        self.title = dock ? "\(title) · Dock" : title
        isReleasedWhenClosed = false
        contentView = frameView
        frameView.onClose = { [weak self] in self?.close() }
        if dock {
            backgroundColor = .black
            collectionBehavior = [.fullScreenPrimary]
            tabbingMode = .disallowed
        } else {
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            isMovableByWindowBackground = true
            collectionBehavior = [.fullScreenNone]
        }

        stream.onFormat = { [weak self] desc, size in self?.frameView.setVideo(size: size, format: desc); self?.fit(animated: true) }
        stream.onFrame = { [weak self] sample in
            guard let self else { return }
            frameView.show(sample)
            // Like iPhone Mirroring: the phone goes dark while you use it from the Mac (⌘O toggles).
            // Dock mode runs on its own display, so the phone stays usable there.
            if !isDock, !darkenedOnce { darkenedOnce = true; stream.setDisplay(on: false) }
        }
        stream.onClipboard = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        fit(animated: false)
        center()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func close() {
        stream.stop()
        super.close()
        onClose()
    }

    /// Sizes the window so the phone is about 80% of the screen's height (or width when landscape).
    func fit(animated: Bool) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if isDock {
            // A normal window: keep the desktop's shape while resizing, start at most of the screen
            let v = frameView.videoAspect
            // Only size it when the desktop's shape changes (first picture), never fighting the user's own resizing
            guard v != dockAspect, !styleMask.contains(.fullScreen) else { return }
            dockAspect = v
            contentAspectRatio = NSSize(width: v, height: 1)
            var w = visible.width * 0.85, h = w / v
            if h > visible.height * 0.85 { h = visible.height * 0.85; w = h * v }
            setContentSize(NSSize(width: w, height: h))
            center()
            return
        }
        let size = frameView.idealSize(maxSize: CGSize(width: visible.width * 0.8, height: visible.height * 0.86) * frameView.zoom)
        var f = frame
        f.origin.y += f.height - size.height
        f.size = size
        f.origin.x = max(visible.minX, min(f.origin.x, visible.maxX - size.width))
        f.origin.y = max(visible.minY, min(f.origin.y, visible.maxY - size.height))
        setFrame(f, display: true, animate: animated)
    }

    func zoom(by factor: CGFloat) {
        guard !isDock else { return }
        frameView.zoom = max(0.5, min(1.3, frameView.zoom * factor))
        fit(animated: true)
    }
}

private func * (s: CGSize, k: CGFloat) -> CGSize { CGSize(width: s.width * k, height: s.height * k) }

@MainActor
final class PhoneFrameView: NSView {
    private let stream: PhoneStream
    /** False in dock mode: no phone body, the picture fills the window. */
    private let bezel: Bool
    private let display = AVSampleBufferDisplayLayer()
    private let screenMask = CAShapeLayer()
    private let camera = CALayer()
    private var videoSize = CGSize(width: 1080, height: 2340)
    private var hovering = false
    var zoom: CGFloat = 1
    var onClose: () -> Void = {}

    init(stream: PhoneStream, bezel: Bool = true) {
        self.stream = stream
        self.bezel = bezel
        super.init(frame: .zero)
        if !bezel { videoSize = CGSize(width: 1920, height: 1200) } // until the desktop's real size arrives
        wantsLayer = true
        layer?.backgroundColor = .clear
        display.videoGravity = .resize
        display.backgroundColor = NSColor.black.cgColor
        display.mask = screenMask
        layer?.addSublayer(display)
        camera.backgroundColor = NSColor.black.cgColor
        camera.borderColor = NSColor(white: 0.18, alpha: 1).cgColor
        layer?.addSublayer(camera)
        camera.isHidden = !bezel
        if !bezel { layer?.backgroundColor = NSColor.black.cgColor }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: geometry (proportions measured from an S25 Ultra: square-ish corners, very thin bezel)

    private var landscape: Bool { videoSize.width > videoSize.height }
    var videoAspect: CGFloat { videoSize.width / videoSize.height }
    private var shortSide: CGFloat { min(screenRect.width, screenRect.height) }

    /// Titanium frame, black bezel and the side-button margin, as fractions of the screen's short side.
    private struct Metrics { let titanium, bezel, buttons, screenRadius: CGFloat }
    private func metrics(short: CGFloat) -> Metrics {
        Metrics(titanium: short * 0.022, bezel: short * 0.024, buttons: short * 0.016, screenRadius: short * 0.055)
    }

    func idealSize(maxSize: CGSize) -> CGSize {
        // Solve for the screen size that fits, then add frame and button margins
        let aspect = videoSize.width / videoSize.height
        var h = maxSize.height, w = h * aspect
        if w > maxSize.width { w = maxSize.width; h = w / aspect }
        let m = metrics(short: min(w, h))
        let pad = m.titanium + m.bezel
        return landscape
            ? CGSize(width: w + pad * 2, height: h + pad * 2 + m.buttons)
            : CGSize(width: w + pad * 2 + m.buttons * 2, height: h + pad * 2)
    }

    private var screenRect: CGRect {
        let b = bounds
        if !bezel {
            // Fit the picture in the window, centred
            let aspect = videoSize.width / videoSize.height
            var w = b.width, h = w / aspect
            if h > b.height { h = b.height; w = h * aspect }
            return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
        }
        // Estimate from bounds: the short side shares a fixed ratio with the frame
        let aspect = videoSize.width / videoSize.height
        let k: CGFloat = 0.022 + 0.024
        if landscape {
            let buttons = 0.016
            let h = b.height / (1 + 2 * k * 1 + buttons)
            let w = h * aspect
            return CGRect(x: (b.width - w) / 2, y: b.height - h - h * k, width: w, height: h)
        } else {
            let w = b.width / (1 + 2 * k + 2 * 0.016)
            let h = w / aspect
            return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
        }
    }

    private var bodyRect: CGRect {
        let m = metrics(short: shortSide)
        return screenRect.insetBy(dx: -(m.titanium + m.bezel), dy: -(m.titanium + m.bezel))
    }

    /// Side buttons in body coordinates: volume rocker then power, on the right edge (top edge in landscape).
    private var buttonRects: [(rect: CGRect, keycode: UInt32)] {
        guard bezel else { return [] }
        let body = bodyRect, m = metrics(short: shortSide)
        let len = landscape ? body.width : body.height
        func seg(_ from: CGFloat, _ to: CGFloat) -> CGRect {
            landscape
                ? CGRect(x: body.maxX - len * to, y: body.minY - m.buttons, width: len * (to - from), height: m.buttons + 2)
                : CGRect(x: body.maxX - 2, y: body.minY + len * from, width: m.buttons + 2, height: len * (to - from))
        }
        let rocker = seg(0.20, 0.33)
        let (up, down) = landscape
            ? (rocker.divided(atDistance: rocker.width / 2, from: .maxXEdge).slice, rocker.divided(atDistance: rocker.width / 2, from: .maxXEdge).remainder)
            : (rocker.divided(atDistance: rocker.height / 2, from: .minYEdge).slice, rocker.divided(atDistance: rocker.height / 2, from: .minYEdge).remainder)
        return [(up, 24), (down, 25), (seg(0.37, 0.44), 26)]
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let s = screenRect, m = metrics(short: shortSide)
        display.frame = s
        let radius = bezel ? m.screenRadius : 0
        screenMask.path = CGPath(roundedRect: CGRect(origin: .zero, size: s.size), cornerWidth: radius, cornerHeight: radius, transform: nil)
        let d = shortSide * 0.03
        let c = landscape ? CGPoint(x: s.minX + shortSide * 0.045, y: s.midY) : CGPoint(x: s.midX, y: s.minY + shortSide * 0.045)
        camera.frame = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        camera.cornerRadius = d / 2
        camera.borderWidth = d * 0.12
        CATransaction.commit()
        needsDisplay = true
    }

    // MARK: drawing the body

    override func draw(_ dirtyRect: NSRect) {
        guard bezel, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let body = bodyRect, m = metrics(short: shortSide)
        let outerRadius = m.screenRadius + m.titanium + m.bezel

        // Side buttons first, so the frame overlaps their inner edge
        for b in buttonRects {
            let p = CGPath(roundedRect: b.rect, cornerWidth: m.buttons * 0.45, cornerHeight: m.buttons * 0.45, transform: nil)
            ctx.addPath(p)
            ctx.clip()
            titanium(ctx, in: b.rect, vertical: !landscape)
            ctx.resetClip()
        }

        // Titanium frame with a brushed, lit-from-above gradient
        let outer = CGPath(roundedRect: body, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil)
        ctx.saveGState()
        ctx.addPath(outer)
        ctx.clip()
        titanium(ctx, in: body, vertical: false)
        // Soft inner rim where the glass meets the metal
        let rimRect = body.insetBy(dx: m.titanium * 0.55, dy: m.titanium * 0.55)
        let rimR = outerRadius - m.titanium * 0.55
        ctx.addPath(CGPath(roundedRect: rimRect, cornerWidth: rimR, cornerHeight: rimR, transform: nil))
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.18).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()

        // Glass front: near-black bezel with a faint reflection
        let glass = body.insetBy(dx: m.titanium, dy: m.titanium)
        let glassR = m.screenRadius + m.bezel
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: glass, cornerWidth: glassR, cornerHeight: glassR, transform: nil))
        ctx.clip()
        ctx.setFillColor(NSColor(white: 0.02, alpha: 1).cgColor)
        ctx.fill(glass)
        let shine = CGGradient(colorsSpace: nil, colors: [NSColor(white: 1, alpha: 0.07).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(shine, start: CGPoint(x: glass.minX, y: glass.minY), end: CGPoint(x: glass.midX, y: glass.midY), options: [])
        ctx.restoreGState()

        // Close button, shown on hover at the top-left corner like a window control
        if hovering {
            let r = closeRect
            ctx.setFillColor(NSColor(white: 0.12, alpha: 0.92).cgColor)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(NSColor(white: 0.85, alpha: 1).cgColor)
            ctx.setLineWidth(1.6)
            ctx.setLineCap(.round)
            let i = r.insetBy(dx: r.width * 0.33, dy: r.height * 0.33)
            ctx.move(to: CGPoint(x: i.minX, y: i.minY)); ctx.addLine(to: CGPoint(x: i.maxX, y: i.maxY))
            ctx.move(to: CGPoint(x: i.maxX, y: i.minY)); ctx.addLine(to: CGPoint(x: i.minX, y: i.maxY))
            ctx.strokePath()
        }
    }

    private func titanium(_ ctx: CGContext, in r: CGRect, vertical: Bool) {
        let colors = [0.42, 0.72, 0.50, 0.30, 0.55, 0.36].map { NSColor(calibratedWhite: $0, alpha: 1).cgColor } as CFArray
        let g = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 0.18, 0.4, 0.62, 0.82, 1])!
        let start = vertical ? CGPoint(x: r.minX, y: r.midY) : CGPoint(x: r.minX, y: r.minY)
        let end = vertical ? CGPoint(x: r.maxX, y: r.midY) : CGPoint(x: r.maxX, y: r.maxY)
        ctx.drawLinearGradient(g, start: start, end: end, options: [])
    }

    private var closeRect: CGRect {
        let d: CGFloat = 18
        return CGRect(x: bodyRect.minX + 4, y: bodyRect.minY + 4, width: d, height: d)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    // MARK: video

    func setVideo(size: CGSize, format: CMVideoFormatDescription) {
        // The phone re-sends encoder settings when its screen turns off or on; keep the current picture
        // unless the size really changed (rotation), since a still screen sends no new frames
        guard size != videoSize else { return }
        videoSize = size
        display.flush()
        needsLayout = true
    }

    func show(_ sample: CMSampleBuffer) {
        if display.status == .failed { display.flush() }
        display.enqueue(sample)
    }

    // MARK: input

    private var touching = false
    private var phoneScreenOn = false

    private func devicePoint(_ event: NSEvent) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let s = screenRect
        guard s.contains(p) || touching else { return nil }
        let x = (p.x - s.minX) / s.width * videoSize.width
        let y = (p.y - s.minY) / s.height * videoSize.height
        return CGPoint(x: max(0, min(videoSize.width - 1, x)), y: max(0, min(videoSize.height - 1, y)))
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bezel, hovering, closeRect.insetBy(dx: -4, dy: -4).contains(p) { onClose(); return }
        if let b = buttonRects.first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(p) }) { stream.key(b.keycode); return }
        if let d = devicePoint(event) {
            touching = true
            stream.touch(.down, at: d, screen: videoSize)
        } else if bezel {
            window?.performDrag(with: event) // the frame moves the phone around
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard touching, let d = devicePoint(event) else { return }
        stream.touch(.move, at: d, screen: videoSize)
    }

    override func mouseUp(with event: NSEvent) {
        guard touching, let d = devicePoint(event) else { return }
        touching = false
        stream.touch(.up, at: d, screen: videoSize)
    }

    override func rightMouseDown(with event: NSEvent) { stream.key(4) }   // back
    override func otherMouseDown(with event: NSEvent) { stream.key(3) }   // home

    override func scrollWheel(with event: NSEvent) {
        guard let d = devicePoint(event) else { return }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 0.08 : 1
        stream.scroll(at: d, screen: videoSize, dx: event.scrollingDeltaX * k, dy: event.scrollingDeltaY * k)
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        if cmd {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "h": stream.key(3)
            case "b": stream.key(4)
            case "s": stream.key(187)
            case "n": stream.expandNotifications()
            case "o":
                phoneScreenOn.toggle()
                stream.setDisplay(on: phoneScreenOn)
            case "w": onClose()
            case "v": if let t = NSPasteboard.general.string(forType: .string) { stream.setClipboard(t, paste: true) }
            case "=", "+": (window as? PhoneWindow)?.zoom(by: 1.1)
            case "-": (window as? PhoneWindow)?.zoom(by: 1 / 1.1)
            default: super.keyDown(with: event)
            }
            return
        }
        // Special keys become Android keycodes; everything else is typed as text
        let special: [UInt16: UInt32] = [36: 66, 76: 66, 51: 67, 117: 112, 48: 61, 53: 111, 123: 21, 124: 22, 125: 20, 126: 19]
        if let code = special[event.keyCode] { stream.key(code); return }
        if let chars = event.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({ $0.value >= 32 }) {
            stream.text(chars)
        }
    }
}
