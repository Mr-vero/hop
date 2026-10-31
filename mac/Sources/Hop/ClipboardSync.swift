import AppKit

/// Universal clipboard: text copied on the Mac appears on the phone's clipboard and the other way round.
///
/// Mac → phone goes over the Hop link (or the debugging connection). Android doesn't let apps read the
/// clipboard in the background, so phone → Mac comes through a quiet scrcpy connection with no picture or
/// sound, which reports the phone's clipboard as it changes. Passwords (copies marked concealed or transient,
/// as password managers and Hop's own codes do) are never synced.
@MainActor
final class ClipboardSync {
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "clipboardSync") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "clipboardSync"); newValue ? start() : stop() }
    }
    /** Sends text to the phone over the Hop link; returns false when it isn't connected. */
    var sendOverLink: (String) -> Bool = { _ in false }
    /** Where the phone is on Wi-Fi (only while the Hop link vouches for it), for the background connection. */
    var phoneIP: () -> String? = { nil }
    /** The phone put something on the Mac's clipboard (shown, so it never happens unnoticed). */
    var onPhoneCopied: (String) -> Void = { _ in }

    private var timer: Timer?
    private var changeCount = NSPasteboard.general.changeCount
    private var lastSynced = ""
    private var stream: PhoneStream?
    private var connecting = false
    private var lastAttempt = Date.distantPast

    func start() {
        guard enabled, timer == nil else { return }
        changeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stream?.stop()
        stream = nil
    }

    private func tick() {
        let pb = NSPasteboard.general
        if pb.changeCount != changeCount {
            changeCount = pb.changeCount
            macCopied(pb)
        }
        // Keep the listening connection up while the phone is reachable; retry every half minute
        if stream == nil, !connecting, Date().timeIntervalSince(lastAttempt) > 30 { connect() }
    }

    private func macCopied(_ pb: NSPasteboard) {
        let types = pb.types ?? []
        if types.contains(.init("org.nspasteboard.ConcealedType")) || types.contains(.init("org.nspasteboard.TransientType")) { return }
        guard let text = pb.string(forType: .string), !text.isEmpty, text != lastSynced, text.utf8.count < 100_000 else { return }
        lastSynced = text
        if let stream { stream.setClipboard(text, paste: false) } else { _ = sendOverLink(text) }
    }

    private func phoneCopied(_ text: String) {
        guard text != lastSynced else { return }
        lastSynced = text
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Clipboard managers and Apple's Universal Clipboard shouldn't keep it: it may be a password copied on the phone
        pb.setString("", forType: .init("org.nspasteboard.TransientType"))
        changeCount = pb.changeCount // our own change: don't send it back
        onPhoneCopied(text)
    }

    private func connect() {
        connecting = true
        lastAttempt = Date()
        Task {
            defer { connecting = false }
            guard let s = try? await Mirror.openStream(phoneIP: phoneIP(), controlOnly: true) else { return }
            s.onClipboard = { [weak self] text in self?.phoneCopied(text) }
            s.onEnded = { [weak self, weak s] _ in
                guard let self, self.stream === s else { return }
                self.stream = nil
            }
            stream = s
            s.start()
        }
    }
}
