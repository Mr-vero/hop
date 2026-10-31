import CoreBluetooth
import CryptoKit
import Foundation

/// Tells how close the paired phone is from the strength of its Bluetooth signal (see NearBeacon.kt).
/// Only the paired phone is recognised: its signal carries a token derived from the pairing key that
/// changes every 5 minutes.
@MainActor
final class NearSensor: NSObject, CBCentralManagerDelegate {
    enum Zone { case far, near }

    static let service = CBUUID(string: "6B0F1E52-8D3A-4C7B-9E21-5A4F3C2D1B0E")

    var onZone: (Zone) -> Void = { _ in }
    var onSignal: (Double?) -> Void = { _ in }
    private(set) var zone = Zone.far
    /** Smoothed signal strength in dBm; nil when the phone isn't being heard. */
    private(set) var rssi: Double?
    private(set) var bluetoothOff = false

    /** dBm at or above which the phone counts as near. Set by calibration. */
    var nearThreshold: Double {
        get { UserDefaults.standard.object(forKey: "nearThreshold") as? Double ?? -55 }
        set { UserDefaults.standard.set(newValue, forKey: "nearThreshold") }
    }

    private var key = Data()
    private var central: CBCentralManager?
    private var lastHeard = Date.distantPast
    private var pending: (zone: Zone, since: Date)?
    private var timer: Timer?
    // Troubleshooting counters, written to Application Support/Hop/near-status.txt
    private var heardAny = 0
    private var heardOurs = 0
    private var lastData = ""
    private var lastWrite = Date.distantPast

    func start(key: Data) {
        self.key = key
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        central?.stopScan()
        central = nil
        timer?.invalidate()
        timer = nil
        rssi = nil
        pending = nil
        set(.far)
    }

    // MARK: Bluetooth

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            bluetoothOff = central.state != .poweredOn
            if central.state == .poweredOn {
                // No service filter: macOS doesn't reliably match non-connectable adverts against one, so Hop
                // listens to everything and keeps only adverts carrying our phone's token
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            }
            onSignal(rssi)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let maker = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let value = RSSI.doubleValue
        MainActor.assumeIsolated { heard(maker, value) }
    }

    private func heard(_ maker: Data?, _ value: Double) {
        // Company id 0xFFFF (little-endian) followed by the 6-byte token; cheap check first, it runs for every advert around
        guard let maker, maker.count == 8, maker.first == 0xFF, maker.dropFirst().first == 0xFF else { return }
        heardAny += 1
        lastData = maker.map { String(format: "%02x", $0) }.joined() + " @\(Int(value))"
        guard value < 0, value > -110,
              isOurPhone(token: maker.suffix(6)) else { return }
        lastHeard = Date()
        heardOurs += 1
        // Smooth out the jumpy readings: roughly the last second and a half
        rssi = rssi.map { $0 * 0.75 + value * 0.25 } ?? value
        evaluate()
    }

    private func isOurPhone(token: Data) -> Bool {
        let window = Int64(Date().timeIntervalSince1970) / 300
        return (window - 1...window + 1).contains { Self.token(key: key, window: $0) == token }
    }

    static func token(key: Data, window: Int64) -> Data {
        var msg = Data("hop-near".utf8)
        withUnsafeBytes(of: window.bigEndian) { msg.append(contentsOf: $0) }
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)).prefix(6))
    }

    // MARK: zones

    private func tick() {
        // Not heard for a while: out of range, or Bluetooth off (Macs catch only some of the phone's packets)
        if rssi != nil, Date().timeIntervalSince(lastHeard) > 8 {
            rssi = nil
            evaluate()
        }
        onSignal(rssi)
        writeStatus()
    }

    private func writeStatus() {
        guard Date().timeIntervalSince(lastWrite) > 2 else { return }
        lastWrite = Date()
        let state = central.map { "\($0.state.rawValue)" } ?? "none"
        let auth = CBManager.authorization.rawValue
        let text = "bluetooth=\(state) (5=on) auth=\(auth) (3=allowed) scanning=\(central?.isScanning ?? false) " +
            "heard=\(heardAny) ours=\(heardOurs) rssi=\(rssi.map { String(Int($0)) } ?? "-") zone=\(zone) last=\(lastData)\n"
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hop/near-status.txt")
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func evaluate() {
        let target = targetZone()
        guard target != zone else { pending = nil; return }
        if pending?.zone != target { pending = (target, Date()) }
        // Open quickly when the phone arrives, close slowly when it leaves, so a passing blip never does either
        let wait: TimeInterval = target == .near ? 1.5 : 5.0
        if let p = pending, Date().timeIntervalSince(p.since) >= wait { set(target) }
    }

    private func targetZone() -> Zone {
        guard let r = rssi else { return .far }
        // A few dB of hysteresis so the zone doesn't flicker at the boundary
        return r >= nearThreshold - (zone == .near ? 6 : 0) ? .near : .far
    }

    private func set(_ z: Zone) {
        pending = nil
        guard z != zone else { return }
        zone = z
        onZone(z)
    }
}
