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
    /** Recent readings (time, dBm). */
    private var samples: [(at: Date, dbm: Double)] = []
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
        samples = []
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
        samples.append((Date(), value))
        filter()
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
        filter()
        evaluate()
        onSignal(rssi)
        writeStatus()
    }

    /// Signal strength from the last 3 seconds. Hands, bodies and the phone lying flat only ever *weaken* the
    /// signal, so the strong end of the recent readings (75th percentile) tracks distance far better than an average.
    private func filter() {
        let now = Date()
        samples.removeAll { now.timeIntervalSince($0.at) > 3 }
        guard !samples.isEmpty else {
            // Macs catch only some packets; only after 6 quiet seconds is the phone really gone (or Bluetooth off)
            if now.timeIntervalSince(lastHeard) > 6 { rssi = nil }
            return
        }
        let sorted = samples.map(\.dbm).sorted()
        rssi = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.75))]
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
        let wait: TimeInterval = target == .near ? 1.0 : 4.0
        if let p = pending, Date().timeIntervalSince(p.since) >= wait { set(target) }
    }

    private func targetZone() -> Zone {
        guard let r = rssi else { return .far }
        // Wide hysteresis: once near, it takes a clearly weaker signal to count as gone
        return r >= nearThreshold - (zone == .near ? 9 : 0) ? .near : .far
    }

    private func set(_ z: Zone) {
        pending = nil
        guard z != zone else { return }
        zone = z
        onZone(z)
    }
}
