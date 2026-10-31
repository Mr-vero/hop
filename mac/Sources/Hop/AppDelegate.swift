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
    // Near the Mac: share the keyboard when close, show the phone when touching
    private let near = NearSensor()
    private let share = KeyboardShare()
    private var autoMirror = false
    private var calibrating = false
    private var nearItem: NSMenuItem?
    private var lastNearFailure = Date.distantPast
    private var nearEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "nearEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "nearEnabled") }
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
        mirror.onChange = { [weak self] in self?.refresh() }
        near.onZone = { [weak self] in self?.nearZoneChanged($0) }
        near.onSignal = { [weak self] _ in self?.nearItem?.title = self?.nearStatus() ?? "" }
        share.onChange = { [weak self] in self?.nearItem?.title = self?.nearStatus() ?? "" }
        // `open Hop.app --args --show-phone` opens the phone screen straight away (handy from Terminal)
        if CommandLine.arguments.contains("--show-phone") { toggleMirror() }
        refresh()
        if !UserDefaults.standard.bool(forKey: "everPaired") { showPairing() }
    }

    // MARK: menu

    private func refresh() {
        let connected = phoneName != nil
        let image = NSImage(systemSymbolName: connected ? "iphone.radiowaves.left.and.right" : "iphone.slash", accessibilityDescription: "Hop")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        let status = NSMenuItem(title: connected ? "Connected to \(phoneName!)" : "Phone not connected", action: nil, keyEquivalent: "")
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
        menu.addItem(item(mirror.isRunning ? "Hide Phone Screen" : "Show Phone Screen", #selector(toggleMirror), "m"))
        let nearToggle = item("Use Phone When It's Near", #selector(toggleNear), "")
        nearToggle.state = nearEnabled ? .on : .off
        menu.addItem(nearToggle)
        nearItem = nil
        if nearEnabled {
            let status = NSMenuItem(title: nearStatus(), action: nil, keyEquivalent: "")
            status.isEnabled = false
            status.indentationLevel = 1
            menu.addItem(status)
            nearItem = status
            if !KeyboardShare.hasPermission {
                let ask = item("⚠︎ Allow Hop to Share Your Keyboard…", #selector(askInputPermission), "")
                ask.indentationLevel = 1
                menu.addItem(ask)
            }
            let cal = item("Calibrate Distance…", #selector(calibrate), "")
            cal.indentationLevel = 1
            menu.addItem(cal)
        }
        menu.addItem(.separator())
        menu.addItem(item("Send File to Phone…", #selector(pickFile), "o", enabled: connected))
        menu.addItem(item("Send Clipboard to Phone", #selector(sendClipboard), "v", enabled: connected))
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
        if mirror.isRunning { mirror.stop(); return }
        share.stop()
        autoMirror = false
        startMirror()
    }

    private func startMirror() {
        Task {
            do {
                try await mirror.start(phoneIP: server.phoneAddress, title: phoneName ?? "Phone")
            } catch Mirror.Failure.notInstalled {
                notify("Phone screen needs scrcpy", "Install it once in Terminal with: brew install scrcpy")
            } catch {
                notify("Couldn't reach your phone's screen",
                       "Plug the phone into this Mac with USB once. After that it also works over Wi-Fi until the phone restarts.")
            }
        }
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
        UserDefaults.standard.set(false, forKey: "everPaired")
        showPairing()
    }

    // MARK: ServerDelegate

    func phoneDidConnect(name: String) {
        phoneName = name
        UserDefaults.standard.set(true, forKey: "everPaired")
        if nearEnabled { near.start(key: server.pairing.key) }
        if pairWindow?.isVisible == true {
            pairWindow?.close()
            notify("Paired with \(name)", "Codes, links and files will now hop between your devices.")
        }
        refresh()
    }

    func phoneDidDisconnect() {
        phoneName = nil
        near.stop()
        share.stop()
        refresh()
    }

    // MARK: near the Mac

    @objc private func toggleNear() {
        nearEnabled.toggle()
        if nearEnabled {
            if !KeyboardShare.hasPermission { KeyboardShare.askPermission() }
            if phoneName != nil { near.start(key: server.pairing.key) }
        } else {
            near.stop()
            share.stop()
            if autoMirror { mirror.stop(); autoMirror = false }
        }
        refresh()
    }

    @objc private func askInputPermission() {
        KeyboardShare.askPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func nearZoneChanged(_ zone: NearSensor.Zone) {
        guard nearEnabled, !calibrating, phoneName != nil else { return }
        switch zone {
        case .touching:
            // Right up against the Mac: show the phone itself
            share.stop()
            if !mirror.isRunning { autoMirror = true; startMirror() }
        case .near:
            if autoMirror, mirror.isRunning { mirror.stop() }
            autoMirror = false
            startSharing()
        case .far:
            share.stop()
            if autoMirror { mirror.stop(); autoMirror = false }
        }
        nearItem?.title = nearStatus()
    }

    private func startSharing() {
        guard !share.isRunning, !mirror.isRunning, KeyboardShare.hasPermission else { return }
        Task {
            do {
                let stream = try await Mirror.openStream(phoneIP: server.phoneAddress, controlOnly: true)
                guard near.zone == .near, !share.isRunning, !mirror.isRunning else { return }
                share.start(stream: stream)
            } catch {
                // Say it once in a while, not every time the phone wanders back
                guard Date().timeIntervalSince(lastNearFailure) > 600 else { return }
                lastNearFailure = Date()
                if case Mirror.Failure.notInstalled = error {
                    notify("Keyboard sharing needs scrcpy", "Install it once in Terminal with: brew install scrcpy")
                } else {
                    notify("Couldn't reach your phone", "Plug it into this Mac with USB once. After that it works over Wi-Fi until the phone restarts.")
                }
            }
        }
    }

    private func nearStatus() -> String {
        if phoneName == nil { return "Waiting for your phone to connect" }
        if near.bluetoothOff { return "Turn on Bluetooth on this Mac" }
        guard let rssi = near.rssi else { return "Phone not sensed. Allow \"Near your Mac\" in Hop on the phone" }
        let signal = "  (\(Int(rssi)) dBm)"
        switch near.zone {
        case .far: return "Not close enough yet" + signal
        case .touching: return "Touching: showing your phone" + signal
        case .near:
            if !KeyboardShare.hasPermission { return "Near: allow keyboard sharing below" + signal }
            if share.onPhone { return "Using the phone. ⌘⎋ or push left to return" + signal }
            if share.ready { return "Near: push the pointer off the right edge" + signal }
            return "Near: connecting to the phone…" + signal
        }
    }

    @objc private func calibrate() {
        guard phoneName != nil else {
            alert("Connect your phone first", "Open Hop on the phone, on the same Wi-Fi as this Mac.")
            return
        }
        if !nearEnabled { toggleNear() }
        near.start(key: server.pairing.key)
        calibrating = true
        share.stop()
        Task {
            defer { calibrating = false; nearZoneChanged(near.zone) }
            guard let touching = await measure("Put your phone against the Mac",
                                               "Hold it right against the right side of the Mac, where the phone screen should pop up. Then click Measure.")
            else { return }
            guard let nearby = await measure("Now put it where you usually keep it",
                                             "For example on the desk beside the Mac. Within this distance your keyboard and mouse can move to the phone. Then click Measure.")
            else { return }
            guard touching > nearby + 4 else {
                alert("Those two spots look the same", "Bluetooth can't tell them apart. Hold the phone closer to the Mac in the first step and try again.")
                return
            }
            near.touchThreshold = max(touching - 4, (touching + nearby) / 2)
            near.nearThreshold = nearby - 6
            alert("All set", "Your keyboard and mouse will move to the phone within that distance, and the phone screen appears when it's against the Mac.")
        }
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
