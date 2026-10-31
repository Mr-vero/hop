import AppKit
import AVFoundation
import QuartzCore

/// Either a borderless window showing the phone as a clean, slim black device (drag its edge to move it; a
/// small toolbar appears above it on hover), or in dock mode an ordinary, resizable Mac window showing the
/// phone's separate desktop display, which can go full screen.
@MainActor
final class PhoneWindow: NSWindow {
    private let frameView: PhoneFrameView
    private let stream: PhoneStream
    let isDock: Bool
    var onClose: () -> Void = {}
    /** The first picture arrived and the window animated in. */
    var onShown: () -> Void = {}
    /** Files dropped onto the phone. */
    var onDropFiles: ([URL]) -> Void = { _ in }
    private(set) var presented = false
    /** Closed with the close button or ⌘W, as opposed to the connection ending or Hop closing it. */
    private(set) var closedByUser = false
    private var closing = false
    private var darkenedOnce = false
    private var dockAspect: CGFloat = 0
    /** An app to bring up once the picture is live. */
    private var pendingApp: String?

    /// Opens an app on the phone (now if the picture is live, otherwise as soon as it is).
    func startApp(_ package: String) {
        if presented { stream.startApp(package) } else { pendingApp = package }
    }

    init(stream: PhoneStream, title: String, dock: Bool = false) {
        self.stream = stream
        isDock = dock
        frameView = PhoneFrameView(stream: stream, bezel: !dock)
        let style: NSWindow.StyleMask = dock ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless]
        super.init(contentRect: NSRect(x: 0, y: 0, width: dock ? 1280 : 400, height: dock ? 800 : 860), styleMask: style, backing: .buffered, defer: false)
        self.title = dock ? "\(title) · Dock" : title
        isReleasedWhenClosed = false
        contentView = frameView
        frameView.onClose = { [weak self] in self?.closedByUser = true; self?.close() }
        frameView.onDropFiles = { [weak self] in self?.onDropFiles($0) }
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

        stream.onFormat = { [weak self] desc, size in
            guard let self else { return }
            frameView.setVideo(size: size, format: desc)
            fit(animated: presented)
        }
        stream.onFrame = { [weak self] sample in
            guard let self else { return }
            frameView.show(sample)
            if !presented {
                present()
                if let app = pendingApp { pendingApp = nil; stream.startApp(app) }
            }
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

    /// The red button of the dock-mode window.
    override func performClose(_ sender: Any?) {
        closedByUser = true
        super.performClose(sender)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func close() {
        guard !closing else { return }
        closing = true
        stream.stop()
        guard presented, isVisible else { finishClose(); return }
        // Shrink back into the island at the top of the screen
        let a = ConnectHUD.anchor
        let end = NSRect(x: a.x - frame.width * 0.08, y: a.y - frame.height * 0.08, width: frame.width * 0.16, height: frame.height * 0.16)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.4)
            animator().setFrame(end, display: true)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.finishClose() }
        })
    }

    private func finishClose() {
        super.close()
        alphaValue = 1
        onClose()
    }

    /// Grows the window out of the island at the top of the screen once there's a picture to show.
    private func present() {
        presented = true
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var target = frame
        if !isDock {
            // The phone appears on the side of the screen it's lying beside
            target.origin.x = visible.maxX - target.width - 48
            target.origin.y = visible.midY - target.height / 2
        }
        let a = ConnectHUD.anchor
        setFrame(NSRect(x: a.x - target.width * 0.08, y: a.y - target.height * 0.08,
                        width: target.width * 0.16, height: target.height * 0.16), display: false)
        alphaValue = 0
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 1.12, 0.35, 1.0) // slight overshoot, like a spring
            animator().setFrame(target, display: true)
            animator().alphaValue = 1
        }
        onShown()
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
    /** False in dock mode: no device or toolbar, the picture fills the window. */
    private let bezel: Bool
    private let device = CALayer()
    private let screen = CALayer()
    private let display = AVSampleBufferDisplayLayer()
    private let toolbar = ToolbarView()
    private var videoSize = CGSize(width: 1080, height: 2340)
    private var hideToolbar: Task<Void, Never>?
    var zoom: CGFloat = 1
    var onClose: () -> Void = {}
    var onDropFiles: ([URL]) -> Void = { _ in }

    /** Space above the phone for the hover toolbar. */
    private static let toolbarSpace: CGFloat = 44

    init(stream: PhoneStream, bezel: Bool = true) {
        self.stream = stream
        self.bezel = bezel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = bezel ? NSColor.clear.cgColor : NSColor.black.cgColor
        if !bezel { videoSize = CGSize(width: 1920, height: 1200) } // until the desktop's real size arrives

        // A slim black body with a hairline edge, and the screen set into it with matching continuous corners
        device.backgroundColor = NSColor.black.cgColor
        device.cornerCurve = .continuous
        device.borderWidth = 1
        device.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        device.isHidden = !bezel
        layer?.addSublayer(device)
        screen.masksToBounds = true
        screen.cornerCurve = .continuous
        screen.backgroundColor = NSColor.black.cgColor
        display.videoGravity = .resize
        screen.addSublayer(display)
        layer?.addSublayer(screen)

        toolbar.alphaValue = 0
        toolbar.isHidden = !bezel
        toolbar.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .close: onClose()
            case .back: stream.key(4)
            case .home: stream.key(3)
            case .recents: stream.key(187)
            }
        }
        addSubview(toolbar)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: geometry

    var videoAspect: CGFloat { videoSize.width / videoSize.height }

    /// Bezel width and screen corner radius for a screen of this size.
    private func bezelWidth(_ short: CGFloat) -> CGFloat { max(6, short * 0.022) }
    private func screenRadius(_ short: CGFloat) -> CGFloat { short * 0.085 }

    func idealSize(maxSize: CGSize) -> CGSize {
        let avail = CGSize(width: maxSize.width, height: maxSize.height - Self.toolbarSpace)
        var h = avail.height, w = h * videoAspect
        if w > avail.width { w = avail.width; h = w / videoAspect }
        let b = bezelWidth(min(w, h))
        return CGSize(width: w + 2 * b, height: h + 2 * b + Self.toolbarSpace)
    }

    private var deviceRect: CGRect {
        let b = bounds
        return CGRect(x: 0, y: Self.toolbarSpace, width: b.width, height: max(0, b.height - Self.toolbarSpace))
    }

    private var screenRect: CGRect {
        guard bezel else {
            // Dock mode: fit the picture in the window, centred
            var w = bounds.width, h = w / videoAspect
            if h > bounds.height { h = bounds.height; w = h * videoAspect }
            return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        }
        let d = deviceRect
        let b = bezelWidth(min(d.width, d.height))
        return d.insetBy(dx: b, dy: b)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let s = screenRect
        let short = min(s.width, s.height)
        let r = bezel ? screenRadius(short) : 0
        screen.frame = s
        screen.cornerRadius = r
        display.frame = CGRect(origin: .zero, size: s.size)
        let d = deviceRect
        device.frame = d
        device.cornerRadius = r + bezelWidth(short)
        CATransaction.commit()
        let t = toolbar.fittingSize
        toolbar.frame = CGRect(x: (bounds.width - t.width) / 2, y: (Self.toolbarSpace - t.height) / 2 - 2, width: t.width, height: t.height)
    }

    // MARK: drag and drop: files dropped on the phone go to it

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight(false)
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDropFiles(urls)
        return true
    }

    private func highlight(_ on: Bool) {
        let target = bezel ? device : screen
        target.borderWidth = on ? 3 : (bezel ? 1 : 0)
        target.borderColor = on ? NSColor.controlAccentColor.cgColor : NSColor(white: 1, alpha: 0.14).cgColor
    }

    // MARK: hover toolbar

    override func mouseEntered(with event: NSEvent) {
        guard bezel else { return }
        hideToolbar?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            toolbar.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard bezel else { return }
        hideToolbar = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled, let self else { return }
            self.fadeToolbar(to: 0)
        }
    }

    private func fadeToolbar(to alpha: CGFloat) {
        let bar = toolbar
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            bar.animator().alphaValue = alpha
        }
    }

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

    override func mouseDown(with event: NSEvent) {
        if let d = devicePoint(event) {
            touching = true
            stream.touch(.down, at: d, screen: videoSize)
        } else if bezel {
            window?.performDrag(with: event) // the edge of the phone moves it around
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
        if event.modifierFlags.contains(.command) {
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

/// The small frosted pill above the phone: close, back, home, recent apps.
@MainActor
private final class ToolbarView: NSVisualEffectView {
    enum Action: CaseIterable { case close, back, home, recents }
    var onAction: (Action) -> Void = { _ in }
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.15).cgColor
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        let items: [(Action, String, String)] = [
            (.close, "xmark", "Close"), (.back, "chevron.backward", "Back"),
            (.home, "circle", "Home"), (.recents, "square.on.square", "Recent apps"),
        ]
        for (action, symbol, tip) in items {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: #selector(tap(_:)))
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
            b.contentTintColor = NSColor(white: 1, alpha: 0.85)
            b.toolTip = tip
            b.tag = Action.allCases.firstIndex(of: action)!
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            stack.addArrangedSubview(b)
        }
        addSubview(stack)
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { stack.fittingSize }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    @objc private func tap(_ sender: NSButton) { onAction(Action.allCases[sender.tag]) }
}
