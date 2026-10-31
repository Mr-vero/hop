import AppKit

/// An iPhone-style "island" at the top centre of the screen that says what the phone connection is doing:
/// connecting, connected, moved away, or what went wrong. On a MacBook with a notch it grows out of the
/// notch and shrinks back into it; elsewhere it drops in just below the top edge.
@MainActor
final class ConnectHUD {
    enum Style { case working, done, info }

    private var panel: NSPanel?
    private let island = IslandView()
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, style: Style, hideAfter: TimeInterval? = nil) {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        island.set(text: text, style: style)
        let expanded = Self.frame(width: island.preferredWidth, expanded: true)
        if !panel.isVisible {
            panel.setFrame(Self.frame(width: 0, expanded: false), display: false)
            panel.alphaValue = Self.notch == nil ? 0 : 1 // from the notch it simply grows; elsewhere it fades in
            island.contentAlpha = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.15, 0.35, 1.0) // springy, like the island
            panel.animator().setFrame(expanded, display: true)
            panel.animator().alphaValue = 1
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            island.animator().contentAlpha = 1
        }
        if let hideAfter {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(hideAfter))
                if !Task.isCancelled { self?.hide() }
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            panel.animator().setFrame(Self.frame(width: 0, expanded: false), display: true)
            island.animator().contentAlpha = 0
            if Self.notch == nil { panel.animator().alphaValue = 0 }
        }, completionHandler: { [weak panel] in
            Task { @MainActor in panel?.orderOut(nil) }
        })
    }

    /// Where the phone window grows out of and shrinks back into: the island.
    static var anchor: CGPoint {
        let f = (NSScreen.main ?? NSScreen.screens[0]).frame
        return CGPoint(x: f.midX, y: f.maxY - 30)
    }

    // MARK: geometry

    private static var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }

    /// The notch's size, if this screen has one.
    private static var notch: CGSize? {
        let s = screen
        guard s.safeAreaInsets.top > 0, let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea else { return nil }
        return CGSize(width: s.frame.width - left.width - right.width, height: s.safeAreaInsets.top)
    }

    private static func frame(width: CGFloat, expanded: Bool) -> NSRect {
        let f = screen.frame
        let notch = notch
        let top = notch?.height ?? 0       // the part hidden behind the notch
        let w: CGFloat, h: CGFloat
        if expanded {
            w = max(width, (notch?.width ?? 0) + 40)
            h = top + IslandView.contentHeight
        } else {
            w = notch?.width ?? 120
            h = notch?.height ?? 8
        }
        let y = notch == nil && expanded ? f.maxY - h - 8 : f.maxY - h // without a notch, float just below the top
        return NSRect(x: f.midX - w / 2, y: y, width: w, height: h)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar // above the menu bar, so it can sit in the notch
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        island.flushTop = Self.notch != nil
        p.contentView = island
        panel = p
        return p
    }
}

/// The black pill itself: icon, message and a spinner or tick, laid out along its bottom edge.
@MainActor
private final class IslandView: NSView {
    static let contentHeight: CGFloat = 40
    var flushTop = true { didSet { needsLayout = true } }
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let spinner = Spinner()
    private let tick = NSImageView()
    /** The message's natural width, measured once per message (the label's own frame gets squeezed while animating). */
    private var textWidth: CGFloat = 0

    @objc dynamic var contentAlpha: CGFloat = 1 {
        didSet { [icon, label, spinner, tick].forEach { $0.alphaValue = contentAlpha } }
    }

    override static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "contentAlpha" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    /// Hop's colours, from the app icon.
    private static let accent = [NSColor(srgbRed: 0.54, green: 0.36, blue: 1, alpha: 1), NSColor(srgbRed: 0.24, green: 0.42, blue: 1, alpha: 1),
                                 NSColor(srgbRed: 0, green: 0.78, blue: 1, alpha: 1)]
    /** A soft wash of colour across the black, and a thin glowing edge that sweeps round while connecting. */
    private let wash = CAGradientLayer()
    private let edge = CALayer()
    private let edgeShape = CAShapeLayer()
    private let sweep = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        wash.type = .radial
        wash.startPoint = CGPoint(x: 0.1, y: 0.0)
        wash.endPoint = CGPoint(x: 1.0, y: 1.6)
        layer?.addSublayer(wash)
        sweep.type = .conic
        sweep.startPoint = CGPoint(x: 0.5, y: 0.5)
        sweep.endPoint = CGPoint(x: 0.5, y: 0)
        edge.addSublayer(sweep)
        edgeShape.fillColor = nil
        edgeShape.strokeColor = NSColor.white.cgColor
        edgeShape.lineWidth = 1.6
        edge.mask = edgeShape
        layer?.addSublayer(edge)
        setColors(Self.accent)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        tick.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        tick.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        tick.contentTintColor = .systemGreen
        [icon, label, spinner, tick].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, style: ConnectHUD.Style) {
        label.stringValue = text
        textWidth = ceil((text as NSString).size(withAttributes: [.font: label.font!]).width) + 4
        // Connecting: the edge sweeps round. Connected: it settles into green. Otherwise: Hop's colours, still.
        setColors(style == .done ? [.systemGreen, NSColor(srgbRed: 0.2, green: 0.9, blue: 0.6, alpha: 1), .systemGreen] : Self.accent)
        sweep.removeAnimation(forKey: "spin")
        if style == .working {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 2.2
            spin.repeatCount = .infinity
            sweep.add(spin, forKey: "spin")
        }
        icon.layer?.removeAnimation(forKey: "breathe")
        if style == .working {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.55
            breathe.duration = 0.8
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            icon.wantsLayer = true
            icon.layer?.add(breathe, forKey: "breathe")
        }
        spinner.isHidden = style != .working
        tick.isHidden = style != .done
        needsLayout = true
    }

    private func setColors(_ c: [NSColor]) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        sweep.colors = (c + [c[0]]).map(\.cgColor)
        wash.colors = [c[0].withAlphaComponent(0.28).cgColor, c[1].withAlphaComponent(0.08).cgColor, NSColor.clear.cgColor]
        CATransaction.commit()
    }

    var preferredWidth: CGFloat { 22 + 22 + 10 + min(textWidth, 320) + 10 + 18 + 22 }

    override func layout() {
        super.layout()
        let h = Self.contentHeight
        // Rounded at the bottom; flush with the top edge when hanging from the notch
        layer?.cornerRadius = min(bounds.height, h) / 2
        layer?.maskedCorners = flushTop ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.frame = bounds
        edge.frame = bounds
        // The conic gradient spins, so it must cover the pill at every angle
        let d = hypot(bounds.width, bounds.height)
        sweep.frame = CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        edgeShape.frame = bounds
        edgeShape.path = edgePath()
        CATransaction.commit()
        let textW = min(textWidth, 320, max(0, bounds.width - 96))
        let contentW = 22 + 10 + textW + 10 + 18
        var x = (bounds.width - contentW) / 2
        let mid = h / 2
        icon.frame = NSRect(x: x, y: mid - 11, width: 22, height: 22); x += 32
        label.frame = NSRect(x: x, y: mid - 9, width: textW, height: 18); x += textW + 10
        spinner.frame = NSRect(x: x, y: mid - 8, width: 16, height: 16)
        tick.frame = NSRect(x: x - 1, y: mid - 9, width: 18, height: 18)
    }

    /// The glowing edge: around the whole pill, or only the sides and bottom when it hangs from the notch.
    private func edgePath() -> CGPath {
        let inset = edgeShape.lineWidth / 2
        let b = bounds.insetBy(dx: inset, dy: inset)
        let r = min(Self.contentHeight / 2, b.height / 2) - inset
        guard flushTop else { return CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil) }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: b.minX, y: bounds.maxY))
        p.addLine(to: CGPoint(x: b.minX, y: b.minY + r))
        p.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY), tangent2End: CGPoint(x: b.minX + r, y: b.minY), radius: r)
        p.addLine(to: CGPoint(x: b.maxX - r, y: b.minY))
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY), tangent2End: CGPoint(x: b.maxX, y: b.minY + r), radius: r)
        p.addLine(to: CGPoint(x: b.maxX, y: bounds.maxY))
        return p
    }
}

/// A small white spinning arc (the system spinner is too dark on the black island).
@MainActor
private final class Spinner: NSView {
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.strokeColor = NSColor.white.cgColor
        arc.fillColor = nil
        arc.lineWidth = 2
        arc.lineCap = .round
        arc.strokeEnd = 0.75
        layer?.addSublayer(arc)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        arc.frame = bounds
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
    }
}
