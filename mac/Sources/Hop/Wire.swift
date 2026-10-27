import CryptoKit
import Foundation

enum HopError: Error {
    case closed, badFrame, badHandshake, replay
}

/// Pairing key shared with the phone through the QR code. Stored with owner-only permissions.
enum PairingKey {
    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pairing.json")
    }

    struct Stored: Codable { var key: Data; var serviceId: String }

    static func load() -> Stored {
        if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Stored.self, from: data) { return s }
        return reset()
    }

    @discardableResult
    static func reset() -> Stored {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let s = Stored(key: Data(bytes), serviceId: String(UUID().uuidString.prefix(8)).lowercased())
        try? JSONEncoder().encode(s).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return s
    }
}

/// Per-connection AES-GCM with strictly increasing counters in each direction.
struct SessionCrypto {
    static let phonePrefix: UInt32 = 1
    static let macPrefix: UInt32 = 2

    let key: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0

    init(pairingKey: Data, phoneRandom: Data, macRandom: Data) {
        var material = Data("hop-v1".utf8)
        material.append(phoneRandom)
        material.append(macRandom)
        let mac = HMAC<SHA256>.authenticationCode(for: material, using: SymmetricKey(data: pairingKey))
        key = SymmetricKey(data: Data(mac))
    }

    private static func nonce(_ prefix: UInt32, _ counter: UInt64) -> Data {
        var d = Data()
        withUnsafeBytes(of: prefix.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: counter.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    mutating func seal(_ plain: Data) throws -> Data {
        let nonceData = Self.nonce(Self.macPrefix, sendCounter)
        sendCounter += 1
        let box = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: nonceData))
        return nonceData + box.ciphertext + box.tag
    }

    mutating func open(_ frame: Data) throws -> Data {
        let bytes = Data(frame)
        guard bytes.count >= 28 else { throw HopError.badFrame }
        let nonceData = bytes.prefix(12)
        guard nonceData == Self.nonce(Self.phonePrefix, recvCounter) else { throw HopError.replay }
        recvCounter += 1
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: bytes.subdata(in: 12..<(bytes.count - 16)),
            tag: bytes.suffix(16)
        )
        return try AES.GCM.open(box, using: key)
    }
}

enum Msg {
    static func json(_ obj: [String: Any]) -> Data {
        var d = Data([0])
        d.append(try! JSONSerialization.data(withJSONObject: obj))
        return d
    }

    static func chunk(_ bytes: Data) -> Data { Data([1]) + bytes }
}
