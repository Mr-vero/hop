import AppKit
import Foundation
import Network

@MainActor
protocol ServerDelegate: AnyObject {
    func phoneDidConnect(name: String)
    func phoneDidDisconnect()
    func received(json: [String: Any])
    func fileStarted(name: String, size: Int64) -> FileHandle?
    func fileFinished(name: String, handle: FileHandle)
}

/// Advertises Hop over Bonjour and keeps at most one phone session.
@MainActor
final class HopServer {
    static let port: NWEndpoint.Port = 47900
    private var listener: NWListener?
    private var session: Session?
    /** Connections that haven't proven they hold the pairing key yet */
    fileprivate var pending = 0
    weak var delegate: ServerDelegate?
    private(set) var pairing = PairingKey.load()
    private(set) var boundPort: UInt16 = 47900

    var serviceName: String { "Hop-\(pairing.serviceId)" }
    /** Wi-Fi address of the connected phone, used to mirror its screen without a cable. */
    private(set) var phoneAddress: String? = UserDefaults.standard.string(forKey: "phoneAddress") {
        didSet { UserDefaults.standard.set(phoneAddress, forKey: "phoneAddress") }
    }
    var isConnected: Bool { session?.phoneName != nil }

    func start() {
        let params = NWParameters.tcp
        let l = (try? NWListener(using: params, on: Self.port)) ?? (try! NWListener(using: params))
        l.service = NWListener.Service(name: serviceName, type: "_hop._tcp")
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state, let p = self?.listener?.port?.rawValue { self?.boundPort = p }
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        l.start(queue: .main)
        listener = l
    }

    func resetPairing() {
        session?.close()
        listener?.cancel()
        pairing = PairingKey.reset()
        start()
    }

    private func accept(_ conn: NWConnection) {
        // Anyone on the Wi-Fi can connect; don't let a flood of strangers crowd out the phone
        guard pending < 4 else { conn.cancel(); return }
        let s = Session(conn: conn, pairingKey: pairing.key, server: self)
        s.start()
    }

    // Session callbacks
    fileprivate func sessionAuthenticated(_ s: Session, name: String) {
        if let old = session, old !== s { old.close() }
        session = s
        phoneAddress = s.remoteIP
        delegate?.phoneDidConnect(name: name)
    }

    fileprivate func sessionClosed(_ s: Session) {
        guard session === s else { return }
        session = nil
        delegate?.phoneDidDisconnect()
    }

    // Outgoing
    func sendText(_ text: String) -> Bool {
        guard let s = session else { return false }
        s.enqueue { try await s.sendJSON(["t": "text", "text": text]) }
        return true
    }

    func sendFile(_ url: URL, progress: @escaping @MainActor (Double) -> Void = { _ in }) -> Bool {
        guard let s = session else { return false }
        s.enqueue { try await s.sendFile(url, progress: progress) }
        return true
    }
}

@MainActor
private final class Session {
    private let conn: NWConnection
    private let pairingKey: Data
    private weak var server: HopServer?
    private var crypto: SessionCrypto?
    private var sendChain: Task<Void, Never>?
    private var closed = false
    private(set) var phoneName: String?

    var remoteIP: String? {
        guard case let .hostPort(host, _) = conn.endpoint else { return nil }
        // "192.168.1.6%en0" or an IPv4-mapped "::ffff:192.168.1.6" both become "192.168.1.6"
        var ip = "\(host)".components(separatedBy: "%")[0]
        if ip.hasPrefix("::ffff:") { ip.removeFirst(7) }
        return ip
    }

    // Incoming file state
    private var fileName = ""
    private var fileRemaining: Int64 = 0
    private var fileHandle: FileHandle?

    init(conn: NWConnection, pairingKey: Data, server: HopServer) {
        self.conn = conn
        self.pairingKey = pairingKey
        self.server = server
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        conn.start(queue: .main)
        server?.pending += 1
        Task { await run() }
        // A real phone finishes the handshake in well under a second
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if let self, self.phoneName == nil { self.close() }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if phoneName == nil { server?.pending -= 1 }
        conn.cancel()
        try? fileHandle?.close()
        server?.sessionClosed(self)
    }

    private func run() async {
        do {
            // Handshake: exchange randoms in the clear, then prove key possession with encrypted hellos
            let hi = try JSONSerialization.jsonObject(with: try await readFrame(max: 512)) as? [String: Any]
            guard hi?["t"] as? String == "hi", let r = hi?["r"] as? String, let phoneRandom = Data(base64Encoded: r), phoneRandom.count == 32
            else { throw HopError.badHandshake }
            let macRandom = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            try await writeFrame(try JSONSerialization.data(withJSONObject: ["t": "hi", "v": 1, "r": macRandom.base64EncodedString()]))
            crypto = SessionCrypto(pairingKey: pairingKey, phoneRandom: phoneRandom, macRandom: macRandom)

            let hello = try await readMessage()
            guard hello.0 == 0, let obj = try JSONSerialization.jsonObject(with: hello.1) as? [String: Any], obj["t"] as? String == "hello"
            else { throw HopError.badHandshake }
            try await sendJSON(["t": "hello", "name": Host.current().localizedName ?? "Mac"])
            phoneName = obj["name"] as? String ?? "Phone"
            server?.pending -= 1
            server?.sessionAuthenticated(self, name: phoneName!)

            while !closed {
                let (type, body) = try await readMessage()
                if type == 1 { handleChunk(body); continue }
                guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { continue }
                switch obj["t"] as? String {
                case "ping": enqueue { try await self.sendJSON(["t": "pong"]) }
                case "pong": break
                case "file":
                    // The protocol never starts a file inside another one
                    guard fileRemaining <= 0 else { throw HopError.badFrame }
                    fileName = (obj["name"] as? String).map { ($0 as NSString).lastPathComponent } ?? "file"
                    fileRemaining = (obj["size"] as? NSNumber)?.int64Value ?? 0
                    fileHandle = server?.delegate?.fileStarted(name: fileName, size: fileRemaining)
                    if fileRemaining == 0 { finishFile() }
                default:
                    server?.delegate?.received(json: obj)
                }
            }
        } catch {
            close()
        }
    }

    private func handleChunk(_ bytes: Data) {
        guard fileRemaining > 0 else { return }
        try? fileHandle?.write(contentsOf: bytes)
        fileRemaining -= Int64(bytes.count)
        if fileRemaining <= 0 { finishFile() }
    }

    private func finishFile() {
        if let h = fileHandle { server?.delegate?.fileFinished(name: fileName, handle: h) }
        fileHandle = nil
    }

    // MARK: sending (serialised so a file transfer is never interleaved)

    func enqueue(_ op: @escaping @MainActor () async throws -> Void) {
        let previous = sendChain
        sendChain = Task { @MainActor in
            await previous?.value
            do { try await op() } catch { self.close() }
        }
    }

    func sendJSON(_ obj: [String: Any]) async throws {
        try await writeEncrypted(Msg.json(obj))
    }

    func sendFile(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        try await sendJSON(["t": "file", "name": url.lastPathComponent, "size": size, "mime": "application/octet-stream"])
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sent: Int64 = 0
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try await writeEncrypted(Msg.chunk(chunk))
            sent += Int64(chunk.count)
            progress(size > 0 ? Double(sent) / Double(size) : 1)
        }
    }

    private func writeEncrypted(_ plain: Data) async throws {
        guard var c = crypto else { throw HopError.badHandshake }
        let sealed = try c.seal(plain)
        crypto = c
        try await writeFrame(sealed)
    }

    private func readMessage() async throws -> (UInt8, Data) {
        guard var c = crypto else { throw HopError.badHandshake }
        let plain = try c.open(try await readFrame())
        crypto = c
        guard let type = plain.first else { throw HopError.badFrame }
        return (type, plain.dropFirst())
    }

    // MARK: framing

    private func readFrame(max: Int = 1 << 20) async throws -> Data {
        let header = try await readExactly(4)
        let len = header.reduce(0) { ($0 << 8) | Int($1) }
        guard len > 0, len <= max else { throw HopError.badFrame }
        return try await readExactly(len)
    }

    private func writeFrame(_ payload: Data) async throws {
        var frame = Data()
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    private func readExactly(_ n: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, error in
                if let error { c.resume(throwing: error) }
                else if let data, data.count == n { c.resume(returning: data) }
                else { c.resume(throwing: HopError.closed) }
            }
        }
    }
}
