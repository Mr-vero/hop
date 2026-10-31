import AppKit

/// A phone notification inside the island: app icon, app name, title and text, with Reply and Dismiss.
@MainActor
final class NotificationCard: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 420
    static let height: CGFloat = 74

    var onReply: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onClose: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onReplying: () -> Void = {}
    /** Clicked on the notification itself: open it on the phone. */
    var onOpen: () -> Void = {}
    private(set) var replying = false

    private let icon = NSImageView()
    private let app = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let text = NSTextField(labelWithString: "")
    private let replyButton = PillButton(symbol: "arrowshape.turn.up.left.fill", tip: "Reply")
    private let dismissButton = PillButton(symbol: "xmark", tip: "Dismiss on phone")
    private let field = NSTextField()

    init(app appName: String, title titleText: String, text body: String, icon image: NSImage?, canReply: Bool) {
        super.init(frame: .zero)
        icon.image = image ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 9
        icon.layer?.cornerCurve = .continuous
        icon.layer?.masksToBounds = true
        app.stringValue = appName.uppercased()
        app.font = .systemFont(ofSize: 10, weight: .semibold)
        app.textColor = NSColor(white: 1, alpha: 0.5)
        title.stringValue = titleText.isEmpty ? appName : titleText
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        text.stringValue = body
        text.font = .systemFont(ofSize: 12)
        text.textColor = NSColor(white: 1, alpha: 0.75)
        [app, title, text].forEach { $0.lineBreakMode = .byTruncatingTail; $0.maximumNumberOfLines = 1 }
        replyButton.isHidden = !canReply
        replyButton.onTap = { [weak self] in self?.startReply() }
        dismissButton.onTap = { [weak self] in self?.onDismiss() }
        field.placeholderString = "Reply…"
        field.font = .systemFont(ofSize: 12)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor(white: 1, alpha: 0.12)
        field.textColor = .white
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 8
        field.delegate = self
        field.isHidden = true
        [icon, app, title, text, replyButton, dismissButton, field].forEach(addSubview)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        guard !replying, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    private func startReply() {
        replying = true
        text.isHidden = true
        replyButton.isHidden = true
        field.isHidden = false
        onReplying()
        window?.makeFirstResponder(field)
        needsLayout = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let reply = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty { onReply(reply) }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onClose(); return true }
        return false
    }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        icon.frame = NSRect(x: 18, y: (h - 38) / 2, width: 38, height: 38)
        let x: CGFloat = 66
        let buttons: CGFloat = replyButton.isHidden ? 34 : 70
        let textW = w - x - buttons - 16
        app.frame = NSRect(x: x, y: h - 24, width: textW, height: 13)
        title.frame = NSRect(x: x, y: h - 41, width: textW, height: 17)
        text.frame = NSRect(x: x, y: h - 58, width: textW, height: 16)
        field.frame = NSRect(x: x, y: h - 64, width: w - x - 52, height: 22)
        dismissButton.frame = NSRect(x: w - 16 - 28, y: (h - 28) / 2, width: 28, height: 28)
        replyButton.frame = NSRect(x: w - 16 - 28 - 34, y: (h - 28) / 2, width: 28, height: 28)
    }
}

/// An incoming call inside the island: who's calling, with round Decline and Answer buttons.
@MainActor
final class CallCard: NSView {
    static let width: CGFloat = 400
    static let height: CGFloat = 66

    var onAnswer: () -> Void = {}
    var onDecline: () -> Void = {}

    private let badge = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let decline = PillButton(symbol: "phone.down.fill", tip: "Decline", tint: .systemRed, size: 36)
    private let answer = PillButton(symbol: "phone.fill", tip: "Answer", tint: .systemGreen, size: 36)

    init(name caller: String, detail info: String) {
        super.init(frame: .zero)
        badge.image = NSImage(systemSymbolName: "phone.badge.waveform.fill", accessibilityDescription: nil)
        badge.symbolConfiguration = .init(pointSize: 20, weight: .semibold)
        badge.contentTintColor = .systemGreen
        badge.addSymbolEffect(.pulse)
        name.stringValue = caller.isEmpty ? "Incoming call" : caller
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.textColor = .white
        detail.stringValue = info.isEmpty ? "Incoming call" : info
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = NSColor(white: 1, alpha: 0.65)
        [name, detail].forEach { $0.lineBreakMode = .byTruncatingTail; $0.maximumNumberOfLines = 1 }
        decline.onTap = { [weak self] in self?.onDecline() }
        answer.onTap = { [weak self] in self?.onAnswer() }
        [badge, name, detail, decline, answer].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        badge.frame = NSRect(x: 20, y: (h - 28) / 2, width: 28, height: 28)
        let x: CGFloat = 60, textW = w - x - 110
        name.frame = NSRect(x: x, y: h / 2, width: textW, height: 18)
        detail.frame = NSRect(x: x, y: h / 2 - 18, width: textW, height: 16)
        answer.frame = NSRect(x: w - 18 - 36, y: (h - 36) / 2, width: 36, height: 36)
        decline.frame = NSRect(x: w - 18 - 36 - 46, y: (h - 36) / 2, width: 36, height: 36)
    }
}

/// A round button with an SF Symbol, used inside the island.
@MainActor
final class PillButton: NSView {
    var onTap: () -> Void = {}
    private let image = NSImageView()
    private let tint: NSColor?

    init(symbol: String, tip: String, tint: NSColor? = nil, size: CGFloat = 28) {
        self.tint = tint
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = size / 2
        layer?.backgroundColor = (tint ?? NSColor(white: 1, alpha: 0.14)).cgColor
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        image.symbolConfiguration = .init(pointSize: size * 0.42, weight: .semibold)
        image.contentTintColor = .white
        toolTip = tip
        addSubview(image)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        image.frame = bounds.insetBy(dx: bounds.width * 0.2, dy: bounds.height * 0.2)
    }

    override func mouseEntered(with event: NSEvent) { layer?.opacity = 0.8 }
    override func mouseExited(with event: NSEvent) { layer?.opacity = 1 }
    override func mouseDown(with event: NSEvent) { layer?.opacity = 0.6 }
    override func mouseUp(with event: NSEvent) {
        layer?.opacity = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onTap() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
