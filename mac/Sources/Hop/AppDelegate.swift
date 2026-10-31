import AppKit
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ServerDelegate, UNUserNotificationCenterDelegate {
    private let server = HopServer()
    private let mirror = Mirror()
    private var statusItem: NSStatusItem!
    private var phoneName: String?
    private var pairWindow: NSWindow?
    private var otpClearTask: Task<Void, Never>?
    private var titleClearTask: Task<Void, Never>?
    /** Latest codes first, so a missed banner never means a lost code. */
    private var recentCodes: [(code: String, from: String, at: Date)] = []
    private var notificationsAllowed = true
    // Near the Mac: the phone (or its dock desktop) appears when the phone is close, and goes when it leaves
    private let near = NearSensor()
    /** The open window was opened because the phone came near, so it closes again when the phone leaves. */
    private var autoMirror = false
    /** Closed by hand while the phone was near: don't reopen until the phone has left and come back. */
    private var dismissedWhileNear = false
    private var calibrating = false
    private var opening = false
    private var lastOpenAttempt = Date.distantPast
    private let hud = ConnectHUD()
    private let clipboard = ClipboardSync()
    /** Battery and signal the phone last reported. */
    private var phoneStatus: (battery: Int, charging: Bool, signal: Int)?
    private var ringing = false
    private var calibrationReply: CheckedContinuation<Int?, Never>?
    private var connectStarted = Date()
    /** One "couldn't connect" message per arrival of the phone, not one per retry. */
    private var toldFailure = false
    private var nearItem: NSMenuItem?
    private var nearEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "nearEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "nearEnabled") }
    }
    /** What appears when the phone comes near: the phone itself, or its desktop (dock mode). */
    private var nearOpensDock: Bool {
        get { UserDefaults.standard.bool(forKey: "nearOpensDock") }
        set { UserDefaults.standard.set(newValue, forKey: "nearOpensDock") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        checkNotificationPermission(ask: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Files dragged onto the menu-bar icon go to the phone
        statusItem.button?.window?.registerForDraggedTypes([.fileURL])
        statusItem.button?.window?.delegate = self

        server.delegate = self
        server.start()
        mirror.onShown = { [weak self] in
            guard let self else { return }
            hud.show("Connected", style: .done, hideAfter: 1.2)
            // Written for troubleshooting: how long connecting took
            let took = String(format: "%.1f", Date().timeIntervalSince(connectStarted))
            let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hop/connect-time.txt")
            try? "\(took) s\n".write(to: file, atomically: true, encoding: .utf8)
        }
        mirror.onFailed = { [weak self] in self?.connectFailed() }
        mirror.onDropFiles = { [weak self] urls, stream in
            guard let self else { return }
            // Over the Hop link the phone shows "Received from Mac"; without it, copy straight over the debugging connection
            if phoneName != nil { send(files: urls) } else { stream.push(urls) }
            hud.show(urls.count == 1 ? "Sending \(urls[0].lastPathComponent)" : "Sending \(urls.count) files", style: .done, hideAfter: 1.5)
        }
        clipboard.sendOverLink = { [weak self] text in self?.server.sendJSON(["t": "clip", "text": text]) ?? false }
        clipboard.phoneIP = { [weak self] in self?.server.phoneAddress }
        clipboard.start()
        mirror.onUserClosed = { [weak self] in
            guard let self else { return }
            // Closed by hand while the phone is still near: respect that until it leaves
            if self.near.zone == .near { self.dismissedWhileNear = true }
            self.autoMirror = false
        }
        mirror.onChange = { [weak self] in self?.refresh() }
        near.onZone = { [weak self] in self?.nearZoneChanged($0) }
        near.onSignal = { [weak self] _ in
            guard let self else { return }
            self.nearItem?.title = self.nearStatus()
            // Still near but nothing showing (e.g. the phone wasn't reachable a moment ago): try again now and then
            if self.near.zone == .near, Date().timeIntervalSince(self.lastOpenAttempt) > 10 { self.nearZoneChanged(.near) }
        }
        // `open Hop.app --args --show-phone` (or `--dock`) opens the phone screen or dock mode straight away
        if CommandLine.arguments.contains("--show-phone") { toggleMirror() }
        if CommandLine.arguments.contains("--dock") { toggleDock() }
        refresh()
        if !UserDefaults.standard.bool(forKey: "everPaired") { showPairing() }
        if nearEnabled { near.start(key: server.pairing.key) }
    }

    // MARK: menu

    private func refresh() {
        let connected = phoneName != nil
        let image = NSImage(systemSymbolName: connected ? "iphone.radiowaves.left.and.right" : "iphone.slash", accessibilityDescription: "Hop")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        var statusText = connected ? "Connected to \(phoneName!)" : "Phone not connected"
        if connected, let st = phoneStatus {
            // e.g. "Connected to Galaxy S25 Ultra · 80% ⚡ · ▂▄▆_"
            statusText += " · \(st.battery)%\(st.charging ? " ⚡" : "")"
            if st.signal >= 0 { statusText += " · " + String("▂▄▆█".prefix(max(1, st.signal))) + String(repeating: "_", count: max(0, 4 - max(1, st.signal))) }
        }
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !connected {
            let hint = NSMenuItem(title: "Open Hop on your phone, on the same Wi-Fi", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        if !notificationsAllowed {
            menu.addItem(item("⚠︎ Turn On Notifications to See Codes…", #selector(openNotificationSettings), ""))
        }
        menu.addItem(.separator())
        let header = NSMenuItem(title: recentCodes.isEmpty ? "No codes yet" : "Recent codes (click to copy)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let ago = RelativeDateTimeFormatter()
        for (i, c) in recentCodes.enumerated() {
            let entry = item("\(c.code)   \(c.from) · \(ago.localizedString(for: c.at, relativeTo: Date()))", #selector(copyRecentCode(_:)), "")
            entry.tag = i
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let showingPhone = mirror.isRunning && !mirror.isDock
        menu.addItem(item(showingPhone ? "Hide Phone Screen" : "Show Phone Screen", #selector(toggleMirror), "m"))
        menu.addItem(item(mirror.isDock ? "Close Dock Mode" : "Dock Mode", #selector(toggleDock), "d"))
        let nearToggle = item("Show Phone When It's Near", #selector(toggleNear), "")
        nearToggle.state = nearEnabled ? .on : .off
        menu.addItem(nearToggle)
        nearItem = nil
        if nearEnabled {
            let status = NSMenuItem(title: nearStatus(), action: nil, keyEquivalent: "")
            status.isEnabled = false
            status.indentationLevel = 1
            menu.addItem(status)
            nearItem = status
            let phone = item("Open the Phone", #selector(nearOpenPhone), "")
            phone.state = nearOpensDock ? .off : .on
            phone.indentationLevel = 1
            menu.addItem(phone)
            let dock = item("Open Dock Mode", #selector(nearOpenDock), "")
            dock.state = nearOpensDock ? .on : .off
            dock.indentationLevel = 1
            menu.addItem(dock)
            let cal = item("Calibrate Distance…", #selector(calibrate), "")
            cal.indentationLevel = 1
            menu.addItem(cal)
        }
        menu.addItem(.separator())
        menu.addItem(item("Send File to Phone…", #selector(pickFile), "o", enabled: connected))
        menu.addItem(item("Send Clipboard to Phone", #selector(sendClipboard), "v", enabled: connected))
        let clip = item("Universal Clipboard", #selector(toggleClipboard), "")
        clip.state = clipboard.enabled ? .on : .off
        menu.addItem(clip)
        menu.addItem(item(ringing ? "Stop Ringing Phone" : "Find My Phone", #selector(toggleRing), "", enabled: connected))
        menu.addItem(.separator())
        menu.addItem(item("Pair Phone…", #selector(showPairing), "p"))
        menu.addItem(item("Open Received Files", #selector(openDownloads), ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit Hop", #selector(NSApplication.terminate(_:)), "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleMirror() {
        if mirror.isRunning, !mirror.isDock { mirror.stop(); return }
        autoMirror = false
        startMirror(dock: false)
    }

    @objc private func toggleDock() {
        if mirror.isDock { mirror.stop(); return }
        autoMirror = false
        startMirror(dock: true)
    }

    /// `quiet`: opened automatically, so don't pop up an error every time it can't reach the phone.
    private func startMirror(dock: Bool, quiet: Bool = false) {
        opening = true
        if !quiet || !toldFailure { hud.show(dock ? "Opening dock mode…" : "Connecting to \(phoneName ?? "your phone")…", style: .working) }
        connectStarted = Date()
        Task {
            defer { opening = false }
            do {
                try await mirror.start(phoneIP: server.phoneAddress, title: phoneName ?? "Phone", dock: dock)
            } catch Mirror.Failure.notInstalled {
                hud.show("Needs scrcpy: brew install scrcpy", style: .info, hideAfter: 5)
            } catch {
                connectFailed()
            }
        }
    }

    private func connectFailed() {
        // Retries while the phone stays near shouldn't flash the same message every 10 seconds
        if toldFailure, autoMirror { hud.hide(); return }
        toldFailure = true
        hud.show("Can't reach the phone. Plug it in by USB once", style: .info, hideAfter: 5)
    }

    @objc private func copyRecentCode(_ sender: NSMenuItem) {
        guard recentCodes.indices.contains(sender.tag) else { return }
        copy(recentCodes[sender.tag].code)
    }

    @objc private func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.phonemod.hop")!)
    }

    private func checkNotificationPermission(ask: Bool) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                if status == .notDetermined, ask {
                    center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                        Task { @MainActor in self.checkNotificationPermission(ask: false) }
                    }
                    return
                }
                self.notificationsAllowed = status == .authorized || status == .provisional
                // Written for troubleshooting: 0 not asked, 1 denied, 2 allowed, 3 provisional
                let statusFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Hop/notification-status.txt")
                try? "\(status.rawValue)".write(to: statusFile, atomically: true, encoding: .utf8)
                self.refresh()
            }
        }
    }

    @objc private func pickFile() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Send to Phone"
        if panel.runModal() == .OK { send(files: panel.urls) }
    }

    @objc private func sendClipboard() {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            send(files: urls)
        } else if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            if server.sendText(text) { notify("Sent to \(phoneName ?? "phone")", text) }
        }
    }

    @objc private func openDownloads() {
        NSWorkspace.shared.open(Self.downloads)
    }

    private func send(files: [URL]) {
        for url in files where !url.hasDirectoryPath {
            _ = server.sendFile(url)
        }
        let names = files.map(\.lastPathComponent).joined(separator: ", ")
        notify("Sending to \(phoneName ?? "phone")", names)
    }

    // MARK: Finder "Open With → Hop", or files dropped on the app icon

    func application(_ application: NSApplication, open urls: [URL]) {
        guard phoneName != nil else {
            notify("Phone not connected", "Open Hop on your phone, on the same Wi-Fi, then try again.")
            return
        }
        send(files: urls)
    }

    // MARK: drag onto the menu-bar icon

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { phoneName == nil ? [] : .copy }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        send(files: urls)
        return true
    }

    // MARK: pairing window

    @objc func showPairing() {
        let p = server.pairing
        let ip = Self.wifiAddress() ?? ""
        let payload = "hop1|\(p.key.base64EncodedString())|\(server.serviceName)|\(ip)|\(server.boundPort)|\(Host.current().localizedName ?? "Mac")"

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        let ci = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: ci)
        let qr = NSImage(size: rep.size)
        qr.addRepresentation(rep)

        let view = NSStackView()
        view.orientation = .vertical
        view.alignment = .centerX
        view.spacing = 14
        view.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 28, right: 32)

        let title = NSTextField(labelWithString: "Pair your phone with Hop")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: "Open Hop on your Galaxy, tap Pair with Mac, and scan this code. Both devices need to be on the same Wi-Fi.")
        body.alignment = .center
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 300
        let imageView = NSImageView(image: qr)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.widthAnchor.constraint(equalToConstant: 260).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 260).isActive = true
        let reset = NSButton(title: "Unpair & Make New Code", target: self, action: #selector(resetPairing))
        reset.bezelStyle = .rounded
        [title, body, imageView, reset].forEach(view.addArrangedSubview)

        pairWindow?.close()
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Hop"
        w.contentView = view
        w.isReleasedWhenClosed = false
        w.center()
        pairWindow = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func resetPairing() {
        server.resetPairing()
        near.stop()
        if nearEnabled { near.start(key: server.pairing.key) }
        UserDefaults.standard.set(false, forKey: "everPaired")
        showPairing()
    }

    // MARK: ServerDelegate

    func phoneDidConnect(name: String) {
        phoneName = name
        UserDefaults.standard.set(true, forKey: "everPaired")
        if pairWindow?.isVisible == true {
            pairWindow?.close()
            notify("Paired with \(name)", "Codes, links and files will now hop between your devices.")
        }
        refresh()
    }

    /// Clicking a notification in the island: the phone opens what it points to (the chat, the email…), and the
    /// phone window opens on the Mac with that app in front.
    private func openNotification(id: String, package: String?) {
        server.sendJSON(["t": "notif-open", "id": id])
        // Android may not let Hop open it from the background; bringing the app up through the window always works,
        // and if the phone already opened the exact chat this just keeps it in front
        if let package { mirror.openApp(package) }
        if !mirror.isRunning {
            autoMirror = false
            startMirror(dock: false)
        } else {
            mirror.focus()
        }
    }

    @objc private func toggleClipboard() {
        clipboard.enabled.toggle()
        refresh()
    }

    @objc private func toggleRing() {
        ringing.toggle()
        server.sendJSON(["t": ringing ? "ring" : "ring-stop"])
        if ringing {
            hud.show("Ringing \(phoneName ?? "your phone")…", style: .working, hideAfter: 3)
            // The phone stops by itself after 30 seconds
            Task { try? await Task.sleep(for: .seconds(30)); self.ringing = false; self.refresh() }
        }
        refresh()
    }

    func phoneDidDisconnect() {
        phoneStatus = nil
        ringing = false
        // Near-Mac features keep going: they use Bluetooth plus USB or wireless debugging, not this link
        phoneName = nil
        refresh()
    }

    // MARK: near the Mac

    @objc private func toggleNear() {
        nearEnabled.toggle()
        if nearEnabled {
            near.start(key: server.pairing.key)
        } else {
            near.stop()
            if autoMirror { mirror.stop(); autoMirror = false }
        }
        refresh()
    }

    @objc private func nearOpenPhone() { nearOpensDock = false; refresh() }
    @objc private func nearOpenDock() { nearOpensDock = true; refresh() }

    private func nearZoneChanged(_ zone: NearSensor.Zone) {
        guard nearEnabled, !calibrating else { return }
        switch zone {
        case .near:
            guard !mirror.isRunning, !dismissedWhileNear, !opening else { break }
            autoMirror = true
            lastOpenAttempt = Date()
            startMirror(dock: nearOpensDock, quiet: true)
        case .far:
            dismissedWhileNear = false
            toldFailure = false
            if autoMirror {
                autoMirror = false
                if mirror.isRunning { hud.show("Phone moved away", style: .info, hideAfter: 2) }
                mirror.stop()
            }
        }
        nearItem?.title = nearStatus()
    }

    private func nearStatus() -> String {
        if near.bluetoothOff { return "Turn on Bluetooth on this Mac" }
        // Prefer the phone's own reading of the Mac's signal: it's the one deciding
        guard let rssi = near.phoneRSSI.map(Double.init) ?? near.rssi else { return "Phone not sensed. Allow \"Near your Mac\" in Hop on the phone" }
        let signal = "  (\(Int(rssi)) dBm\(near.phoneRSSI != nil ? ", from phone" : ""))"
        switch near.zone {
        case .far: return "Not close enough yet" + signal
        case .near:
            if mirror.isShowing { return "Near: showing your phone" + signal }
            if mirror.isRunning { return "Near: connecting…" + signal }
            if dismissedWhileNear { return "Near: closed by you, opens again next time" + signal }
            return "Near: opening…" + signal
        }
    }

    @objc private func calibrate() {
        if !nearEnabled { toggleNear() }
        near.start(key: server.pairing.key)
        calibrating = true
        Task {
            defer { calibrating = false; nearZoneChanged(near.zone) }
            // A phone that judges distance itself measures the Mac's signal, more steadily than the Mac can
            if phoneName != nil {
                NSApp.activate()
                let a = NSAlert()
                a.messageText = "Put your phone where it should count as near"
                a.informativeText = "For example on the desk right beside the Mac. Closer than this, the phone appears on the Mac; farther, it goes away. Then click Measure."
                a.addButton(withTitle: "Measure")
                a.addButton(withTitle: "Cancel")
                guard a.runModal() == .alertFirstButtonReturn else { return }
                try? await Task.sleep(for: .seconds(3)) // let the phone's reading settle at the new spot
                let r: Int? = await withCheckedContinuation { cont in
                    calibrationReply = cont
                    server.sendJSON(["t": "near-calibrate"])
                    Task { try? await Task.sleep(for: .seconds(5)); self.finishCalibration(nil) }
                }
                if let r {
                    alert("All set", "Your phone measured the Mac at \(r) dBm there. It will appear on the Mac when it's about this close, and go away when you take it farther.")
                    return
                }
                // The phone couldn't hear the Mac yet: fall back to the Mac measuring the phone
            }
            guard let nearby = await measure("Put your phone where it should count as near",
                                             "For example on the desk right beside the Mac. Closer than this, the phone appears on the Mac; farther, it goes away. Then click Measure.")
            else { return }
            near.nearThreshold = nearby - 3
            alert("All set", "Your phone will appear on the Mac when it's about this close, and go away when you take it farther.")
        }
    }

    private func finishCalibration(_ rssi: Int?) {
        calibrationReply?.resume(returning: rssi)
        calibrationReply = nil
    }

    /** Asks the user to place the phone, then averages its signal for a few seconds. */
    private func measure(_ title: String, _ text: String) async -> Double? {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "Measure")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        try? await Task.sleep(for: .seconds(1.5)) // let the smoothed signal settle at the new spot
        var samples: [Double] = []
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(300))
            if let r = near.rssi { samples.append(r) }
        }
        guard samples.count >= 5 else {
            alert("Hop can't hear your phone", "On the phone, open Hop and allow \"Near your Mac\". Make sure Bluetooth is on on both devices.")
            return nil
        }
        return samples.sorted()[samples.count / 2]
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    func received(json: [String: Any]) {
        switch json["t"] as? String {
        case "otp":
            guard let code = json["code"] as? String else { return }
            let from = json["from"] as? String ?? "your phone"
            copy(code, concealed: true)
            notify("Code \(code) copied", "From \(from). Paste it with ⌘V.")
            recentCodes.insert((code, from, Date()), at: 0)
            recentCodes = Array(recentCodes.prefix(5))
            // Show the code right in the menu bar for a while, so it's visible even without banners
            statusItem.button?.title = " \(code)"
            statusItem.button?.imagePosition = .imageLeading
            titleClearTask?.cancel()
            titleClearTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { self.statusItem.button?.title = "" }
            }
            checkNotificationPermission(ask: false)
            refresh()
            // Wipe the code from the clipboard after two minutes unless something else was copied
            let stamp = NSPasteboard.general.changeCount
            otpClearTask?.cancel()
            otpClearTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                if !Task.isCancelled, NSPasteboard.general.changeCount == stamp { NSPasteboard.general.clearContents() }
            }
        case "text":
            guard let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()), !text.contains(" ") {
                NSWorkspace.shared.open(url)
            } else {
                copy(text)
                notify("Copied from \(phoneName ?? "phone")", text)
            }
        case "near":
            let rssi = (json["rssi"] as? NSNumber)?.intValue
            near.phoneSaid(near: json["near"] as? Bool, rssi: rssi)
        case "near-calibrated":
            finishCalibration((json["ok"] as? Bool) == true ? (json["rssi"] as? NSNumber)?.intValue : nil)
        case "status":
            phoneStatus = ((json["battery"] as? NSNumber)?.intValue ?? 0, json["charging"] as? Bool ?? false,
                           (json["signal"] as? NSNumber)?.intValue ?? -1)
            refresh()
        case "notif":
            guard let id = json["id"] as? String else { return }
            let icon = (json["icon"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            hud.showNotification(id: id, app: json["app"] as? String ?? "", title: json["title"] as? String ?? "",
                                 text: json["text"] as? String ?? "", icon: icon, canReply: json["reply"] as? Bool ?? false,
                                 onReply: { [weak self] text in self?.server.sendJSON(["t": "notif-reply", "id": id, "text": text]) },
                                 onDismiss: { [weak self] in self?.server.sendJSON(["t": "notif-dismiss", "id": id]) },
                                 onOpen: { [weak self] in self?.openNotification(id: id, package: json["pkg"] as? String) })
        case "notif-gone":
            if let id = json["id"] as? String { hud.removeNotification(id: id) }
        case "call":
            switch json["state"] as? String {
            case "ringing":
                hud.showCall(name: json["name"] as? String ?? "", detail: json["detail"] as? String ?? "",
                             onAnswer: { [weak self] in self?.server.sendJSON(["t": "call-answer"]) },
                             onDecline: { [weak self] in self?.server.sendJSON(["t": "call-decline"]) })
            case "active": hud.callEnded("On a call on your phone")
            default: hud.callEnded()
            }
        default:
            break
        }
    }

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    func fileStarted(name: String, size: Int64) -> FileHandle? {
        // Leave room on the disk rather than letting a transfer fill it
        let free = (try? Self.downloads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        guard size >= 0, free - size > 1 << 30 else {
            notify("Not enough space", "\(name) from your phone wasn't saved.")
            return nil
        }
        var url = Self.uniqueURL(for: name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        // Mark it as downloaded, so Gatekeeper checks it before anything in it can run
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Hop",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload]
        try? url.setResourceValues(values)
        receivingPaths[ObjectIdentifier(self)] = url
        return try? FileHandle(forWritingTo: url)
    }

    private var receivingPaths: [ObjectIdentifier: URL] = [:]

    func fileFinished(name: String, handle: FileHandle) {
        try? handle.close()
        guard let url = receivingPaths.removeValue(forKey: ObjectIdentifier(self)) else { return }
        notify("Received \(url.lastPathComponent)", "Saved to Downloads. Click to show it.", userInfo: ["path": url.path])
    }

    // MARK: helpers

    private func copy(_ text: String, concealed: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Codes are secrets: ask clipboard managers not to keep them (nspasteboard.org convention)
        if concealed {
            NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
    }

    private func notify(_ title: String, _ body: String, userInfo: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
    }

    private static func uniqueURL(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = downloads.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    private static func wifiAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var p = ifaddr
        while let a = p?.pointee {
            if a.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: a.ifa_name).hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(a.ifa_addr, socklen_t(a.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            p = a.ifa_next
        }
        return nil
    }
}
