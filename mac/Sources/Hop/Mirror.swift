import AppKit

/// Shows the phone's screen in Hop's own Galaxy-shaped window. Uses scrcpy's on-phone server
/// (brew install scrcpy). Prefers the USB cable; otherwise connects over Wi-Fi with adb, which only
/// accepts computers the phone has already approved for debugging.
@MainActor
final class Mirror {
    /// Homebrew's prefix: /opt/homebrew on Apple silicon, /usr/local on Intel
    private static let prefix = ["/opt/homebrew", "/usr/local"]
        .first { FileManager.default.fileExists(atPath: "\($0)/bin/adb") } ?? "/opt/homebrew"
    private static let brew = "\(prefix)/bin"
    private var window: PhoneWindow?
    /** Showing, or still connecting. */
    var isRunning: Bool { window != nil }
    var onChange: () -> Void = {}
    /** The window is up with a live picture. */
    var onShown: () -> Void = {}
    /** It didn't get as far as showing a picture. */
    var onFailed: () -> Void = {}
    /** The user closed the window themselves. */
    var onUserClosed: () -> Void = {}
    /** Files dropped onto the phone window, with that window's connection (to copy over directly if needed). */
    var onDropFiles: ([URL], PhoneStream) -> Void = { _, _ in }

    static var isInstalled: Bool { serverJar != nil }

    /// scrcpy's server jar and its version, which the server checks against what we pass
    private static var serverJar: (path: String, version: String)? {
        let cellar = "\(prefix)/Cellar/scrcpy"
        guard let version = (try? FileManager.default.contentsOfDirectory(atPath: cellar))?.sorted().last else { return nil }
        let path = "\(cellar)/\(version)/share/scrcpy/scrcpy-server"
        return FileManager.default.fileExists(atPath: path) ? (path, version) : nil
    }

    enum Failure: Error { case notInstalled, noPhone }

    /// A connection to the phone (not started yet). `phoneIP` is the address of the phone's Hop
    /// connection, used when there's no cable.
    static func openStream(phoneIP: String?, newDisplay: String? = nil, controlOnly: Bool = false) async throws -> PhoneStream {
        guard let jar = serverJar else { throw Failure.notInstalled }
        // A background connection never restarts the phone's adb (which would cut off an open phone window)
        let serial = try await findPhone(phoneIP: phoneIP, setUpWireless: !controlOnly)
        return PhoneStream(config: .init(serial: serial, adb: "\(brew)/adb", serverJar: jar.path, serverVersion: jar.version,
                                         wireless: serial.contains(":"), newDisplay: newDisplay, controlOnly: controlOnly))
    }

    /// Shows the phone in Hop's phone-shaped window, or with `dock` its desktop in a big Mac window.
    func start(phoneIP: String?, title: String, dock: Bool = false) async throws {
        if let window, window.isVisible {
            if window.isDock == dock { window.makeKeyAndOrderFront(nil); return }
            window.close() // switching between phone and dock
        }
        let stream = try await Self.openStream(phoneIP: phoneIP, newDisplay: dock ? Self.dockDisplaySize() : nil)
        let w = PhoneWindow(stream: stream, title: title, dock: dock)
        w.onClose = { [weak self, weak w] in
            guard let self, self.window === w else { return }
            self.window = nil
            if w?.presented == false { self.onFailed() }
            if w?.closedByUser == true { self.onUserClosed() }
            self.onChange()
        }
        w.onShown = { [weak self] in self?.onShown(); self?.onChange() }
        w.onDropFiles = { [weak self, weak stream] urls in
            guard let self, let stream else { return }
            self.onDropFiles(urls, stream)
        }
        stream.onEnded = { [weak w] _ in w?.close() }
        stream.start()
        window = w
        if let app = pendingApp { pendingApp = nil; w.startApp(app) }
        onChange()
        // The window stays hidden until the first picture; give up if none comes
        Task { [weak self, weak w] in
            try? await Task.sleep(for: .seconds(15))
            if let w, w.presented == false, self?.window === w { w.close() }
        }
    }

    func stop() {
        window?.close()
    }

    func focus() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    var isDock: Bool { window?.isDock == true }

    /** An app to open on the phone once the window is up. */
    private var pendingApp: String?

    /// Opens an app on the phone inside Hop's window (opening the window first if needed is up to the caller).
    func openApp(_ package: String) {
        if let window { window.startApp(package) } else { pendingApp = package }
    }
    var isShowing: Bool { window?.presented == true }

    /// A desktop display shaped like this Mac's screen, about 1920 pixels wide.
    private static func dockDisplaySize() -> String {
        let f = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1512, height: 945)
        let w = 1920, h = Int(Double(w) * f.height / f.width) / 8 * 8
        return "\(w)x\(h)/200"
    }

    // MARK: adb

    private static func findPhone(phoneIP: String?, setUpWireless: Bool = true) async throws -> String {
        let devices = try await adb(["devices"])
            .split(separator: "\n").dropFirst()
            .compactMap { line -> String? in
                let cols = line.split(separator: "\t")
                return cols.count == 2 && cols[1] == "device" ? String(cols[0]) : nil
            }
        // A cable shows up as a bare serial; emulators do too ("emulator-5554") but are never the user's phone.
        if let usb = devices.first(where: { !$0.contains(":") && !$0.hasPrefix("emulator-") }) {
            // While the cable is in, switch on wireless debugging so next time works without it
            // (it stays on until the phone restarts). This briefly restarts adb on the phone.
            if setUpWireless, let ip = phoneIP, !devices.contains("\(ip):5555") {
                _ = try? await adb(["-s", usb, "tcpip", "5555"])
                try? await Task.sleep(for: .seconds(2))
                _ = try? await adb(["connect", "\(ip):5555"])
                _ = try? await adb(["-s", usb, "wait-for-device"])
            }
            return usb
        }
        // Over Wi-Fi, only the address the encrypted Hop link reports for the paired phone. Wireless adb never proves
        // who's on the other end, so guessing (the router, old addresses) could hand the clipboard, files and typing
        // to some other device on a café network.
        if let ip = phoneIP {
            let target = "\(ip):5555"
            if devices.contains(target) { return target }
            let out = (try? await adb(["connect", target])) ?? ""
            if out.contains("connected to") { return target }
        }
        throw Failure.noPhone
    }

    @discardableResult
    private static func adb(_ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "\(brew)/adb")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { _ in
                cont.resume(returning: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
