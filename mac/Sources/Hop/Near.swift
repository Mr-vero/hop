import CoreBluetooth
import CryptoKit
import Foundation

/// Tells how close the paired phone is from the strength of its Bluetooth signal (see NearBeacon.kt).
/// Only the paired phone is recognised: its signal carries a token derived from the pairing key that
/// changes every 5 minutes.
@MainActor
final class NearSensor: NSObject, CBCentralManagerDelegate {
    enum Zone: Int, Comparable {
        case far, near, touching
        static func < (a: Zone, b: Zone) -> Bool { a.rawValue < b.rawValue }
    }

    static let service = CBUUID(string: "6B0F1E52-8D3A-4C7B-9E21-5A4F3C2D1B0E")

    var onZone: (Zone) -> Void = { _ in }
    var onSignal: (Double?) -> Void = { _ in }
    private(set) var zone = Zone.far
    /** Smoothed signal strength in dBm; nil when the phone isn't being heard. */
    private(set) var rssi: Double?
    private(set) var bluetoothOff = false

    /** dBm at or above which the phone counts as near / touching. Set by calibration. */
    var nearThreshold: Double {
        get { UserDefaults.standard.object(forKey: "nearThreshold") as? Double ?? -62 }
        set { UserDefaults.standard.set(newValue, forKey: "nearThreshold") }
    }
    var touchThreshold: Double {
        get { UserDefaults.standard.object(forKey: "touchThreshold") as? Double ?? -40 }
        set { UserDefaults.standard.set(newValue, forKey: "touchThreshold") }
    }

    private var key = Data()
    private var central: CBCentralManager?
    private var lastHeard = Date.distantPast
    private var pending: (zone: Zone, since: Date)?
    private var timer: Timer?

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
                central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
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
        // Company id 0xFFFF (little-endian) followed by the 6-byte token
        guard let maker, maker.count == 8, maker.prefix(2) == Data([0xFF, 0xFF]), value < 0, value > -110,
              isOurPhone(token: maker.suffix(6)) else { return }
        lastHeard = Date()
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
        // Not heard for a few seconds: out of range, phone locked away, or Bluetooth off
        if rssi != nil, Date().timeIntervalSince(lastHeard) > 4 {
            rssi = nil
            evaluate()
        }
        onSignal(rssi)
    }

    private func evaluate() {
        let target = targetZone()
        guard target != zone else { pending = nil; return }
        if pending?.zone != target { pending = (target, Date()) }
        // Move closer quickly, move away slowly, so a passing blip never opens or closes anything
        let wait: TimeInterval = target > zone ? (target == .touching ? 1.0 : 1.5) : (zone == .touching ? 2.0 : 4.0)
        if let p = pending, Date().timeIntervalSince(p.since) >= wait { set(target) }
    }

    private func targetZone() -> Zone {
        guard let r = rssi else { return .far }
        // A few dB of hysteresis so the zone doesn't flicker at the boundary
        let touch = touchThreshold - (zone == .touching ? 5 : 0)
        let near = nearThreshold - (zone >= .near ? 5 : 0)
        return r >= touch ? .touching : r >= near ? .near : .far
    }

    private func set(_ z: Zone) {
        pending = nil
        guard z != zone else { return }
        zone = z
        onZone(z)
    }
}
