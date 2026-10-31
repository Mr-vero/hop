import AppKit

/// A small glassy pill at the right edge of the screen (where the phone sits) that says what the phone
/// connection is doing: connecting, connected, moved away, or what went wrong. Slides in and out.
@MainActor
final class ConnectHUD {
    enum Style { case working, done, info }

    private var panel: NSPanel?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, style: Style, hideAfter: TimeInterval? = nil) {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        label.stringValue = text
        let symbol = switch style {
        case .working: "iphone.gen3.radiowaves.left.and.right"
        case .done: "checkmark.circle.fill"
        case .info: "iphone.gen3"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = style == .done ? .systemGreen : .labelColor
        icon.removeAllSymbolEffects()
        if style == .working { icon.addSymbolEffect(.pulse) }
        spinner.isHidden = style != .working
        if style == .working { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        layout(panel)

        let target = restingFrame(for: panel)
        if !panel.isVisible {
            // Slide in from just past the right edge
            panel.setFrame(target.offsetBy(dx: 60, dy: 0), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
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
        let out = panel.frame.offsetBy(dx: 60, dy: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(out, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            Task { @MainActor in panel?.orderOut(nil) }
        })
    }

    /// The point on screen the phone window grows out of and shrinks back into.
    static var edgeAnchor: CGPoint {
        let v = NSScreen.main?.visibleFrame ?? .zero
        return CGPoint(x: v.maxX - 24, y: v.midY)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.state = .active
        glass.blendingMode = .behindWindow
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 22
        glass.layer?.masksToBounds = true
        p.contentView = glass
        icon.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        [icon, label, spinner].forEach(glass.addSubview)
        panel = p
        return p
    }

    private func layout(_ p: NSPanel) {
        label.sizeToFit()
        let textWidth = min(label.frame.width, 300)
        let width = 16 + 22 + 10 + textWidth + (spinner.isHidden ? 18 : 10 + 16 + 16)
        p.setContentSize(NSSize(width: width, height: 44))
        icon.frame = NSRect(x: 16, y: 11, width: 22, height: 22)
        label.frame = NSRect(x: 48, y: (44 - label.frame.height) / 2, width: textWidth, height: label.frame.height)
        spinner.frame = NSRect(x: 48 + textWidth + 10, y: 14, width: 16, height: 16)
    }

    private func restingFrame(for p: NSPanel) -> NSRect {
        let v = NSScreen.main?.visibleFrame ?? .zero
        let s = p.frame.size
        return NSRect(x: v.maxX - s.width - 16, y: v.midY + 140, width: s.width, height: s.height)
    }
}
