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
    var isRunning: Bool { window?.isVisible == true }
    var onChange: () -> Void = {}

    static var isInstalled: Bool { serverJar != nil }

    /// scrcpy's server jar and its version, which the server checks against what we pass
    private static var serverJar: (path: String, version: String)? {
        let cellar = "\(prefix)/Cellar/scrcpy"
        guard let version = (try? FileManager.default.contentsOfDirectory(atPath: cellar))?.sorted().last else { return nil }
        let path = "\(cellar)/\(version)/share/scrcpy/scrcpy-server"
        return FileManager.default.fileExists(atPath: path) ? (path, version) : nil
    }

    enum Failure: Error { case notInstalled, noPhone }

    /// Starts mirroring. `phoneIP` is the address of the phone's Hop connection, used when there's no cable.
    func start(phoneIP: String?, title: String) async throws {
        guard let jar = Self.serverJar else { throw Failure.notInstalled }
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let serial = try await Self.findPhone(phoneIP: phoneIP)

        let stream = PhoneStream(config: .init(serial: serial, adb: "\(Self.brew)/adb", serverJar: jar.path,
                                               serverVersion: jar.version, wireless: serial.contains(":")))
        let w = PhoneWindow(stream: stream, title: title)
        w.onClose = { [weak self] in self?.window = nil; self?.onChange() }
        stream.onEnded = { [weak w] _ in w?.close() }
        stream.start()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        onChange()
    }

    func stop() {
        window?.close()
    }

    // MARK: adb

    private static func findPhone(phoneIP: String?) async throws -> String {
        let devices = try await adb(["devices"])
            .split(separator: "\n").dropFirst()
            .compactMap { line -> String? in
                let cols = line.split(separator: "\t")
                return cols.count == 2 && cols[1] == "device" ? String(cols[0]) : nil
            }
        if let usb = devices.first(where: { !$0.contains(":") }) {
            // While the cable is in, switch on wireless debugging so next time works without it
            // (it stays on until the phone restarts). This briefly restarts adb on the phone.
            if let ip = phoneIP, !devices.contains("\(ip):5555") {
                _ = try? await adb(["-s", usb, "tcpip", "5555"])
                try? await Task.sleep(for: .seconds(2))
                _ = try? await adb(["connect", "\(ip):5555"])
                _ = try? await adb(["-s", usb, "wait-for-device"])
            }
            return usb
        }
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
