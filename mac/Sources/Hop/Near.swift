import CoreBluetooth
import CryptoKit
import Foundation

/// Tells how close the paired phone is from the strength of its Bluetooth signal (see NearBeacon.kt).
/// Only the paired phone is recognised: its signal carries a token derived from the pairing key that
/// changes every 5 minutes.
@MainActor
final class NearSensor: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate {
    enum Zone { case far, near }

    static let service = CBUUID(string: "6B0F1E52-8D3A-4C7B-9E21-5A4F3C2D1B0E")
    /** The Mac's own signal, which the phone listens for to judge the distance itself (NearScanner.kt). */
    static let macService = CBUUID(string: "6B0F1E53-8D3A-4C7B-9E21-5A4F3C2D1B0E")

    var onZone: (Zone) -> Void = { _ in }
    var onSignal: (Double?) -> Void = { _ in }
    private(set) var zone = Zone.far
    /** Smoothed signal strength in dBm; nil when the phone isn't being heard. */
    private(set) var rssi: Double?
    private(set) var bluetoothOff = false

    /** dBm at or above which the phone counts as near. Set by calibration. */
    var nearThreshold: Double {
        get { UserDefaults.standard.object(forKey: "nearThreshold") as? Double ?? -45 }
        set { UserDefaults.standard.set(newValue, forKey: "nearThreshold") }
    }

    private var key = Data()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheralManager?
    private var advertisedWindow: Int64 = -1
    /** The phone's verdict over the encrypted Hop link (can open or close), and when it last said so. */
    private var phoneVerdict: (near: Bool, at: Date)?
    /** When the phone's Bluetooth packets last said "away". Packets can be recorded and replayed, so they only close. */
    private var advertAway: Date?
    /** The phone's measurement of the Mac's signal, for the menu readout. */
    private(set) var phoneRSSI: Int?
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
        peripheral = CBPeripheralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
    }

    func stop() {
        central?.stopScan()
        central = nil
        scanningWithDuplicates = nil
        peripheral?.stopAdvertising()
        peripheral = nil
        advertisedWindow = -1
        phoneVerdict = nil
        advertAway = nil
        phoneRSSI = nil
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
                scan()
            }
            onSignal(rssi)
        }
    }

    private var scanningWithDuplicates: Bool?

    /// Every packet while the Mac has to measure the distance itself; far fewer once the phone's verdicts decide,
    /// since every advert nearby (hundreds a second in an office) would otherwise wake Hop.
    private func scan() {
        guard let central, central.state == .poweredOn else { return }
        let fresh = phoneVerdict.map { Date().timeIntervalSince($0.at) < 30 } ?? false
        guard scanningWithDuplicates != !fresh else { return }
        scanningWithDuplicates = !fresh
        central.stopScan()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: !fresh])
    }

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { advertise() }
    }

    /// Sends the Mac's own small signal, named with a token from the pairing key that changes every 5 minutes.
    private func advertise() {
        guard let peripheral, peripheral.state == .poweredOn else { return }
        let window = Int64(Date().timeIntervalSince1970) / 300
        guard window != advertisedWindow else { return }
        advertisedWindow = window
        peripheral.stopAdvertising()
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.macService],
                                     CBAdvertisementDataLocalNameKey: Self.macName(key: key, window: window)])
    }

    /// "H" plus the first 6 hex digits of the Mac's token, the same as NearScanner.macName on the phone.
    /// Short enough to fit in one Bluetooth packet beside the service ID (longer names get cut off).
    static func macName(key: Data, window: Int64) -> String {
        "H" + token(key: key, label: "hop-mac", window: window).map { String(format: "%02x", $0) }.joined().prefix(6)
    }

    /// The phone's verdict over the Hop link: instant, and authenticated by the link's encryption.
    func phoneSaid(near: Bool?, rssi: Int?) {
        phoneVerdict = near.map { ($0, Date()) }
        phoneRSSI = rssi == 0 ? nil : rssi
        evaluate()
        onSignal(self.rssi)
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
        guard value < 0, value > -110, let flag = ourPhone(token: maker.suffix(6)) else { return }
        // Packets from a phone that judges distance itself carry its verdict, sealed with the pairing key
        if flag == 2 { advertAway = Date() }
        lastHeard = Date()
        heardOurs += 1
        samples.append((Date(), value))
        filter()
    }

    /// nil if it isn't our phone; otherwise 0 (no verdict), 1 (near) or 2 (away).
    private func ourPhone(token: Data) -> UInt8? {
        let window = Int64(Date().timeIntervalSince1970) / 300
        for w in window - 1...window + 1 {
            for flag: UInt8? in [nil, 1, 2] where Self.token(key: key, label: "hop-near", window: w, flag: flag) == token {
                return flag ?? 0
            }
        }
        return nil
    }

    /// First 6 bytes of HMAC-SHA256(pairingKey, label || window [|| flag]), the same as NearCrypto.token on the phone.
    static func token(key: Data, label: String, window: Int64, flag: UInt8? = nil) -> Data {
        var msg = Data(label.utf8)
        withUnsafeBytes(of: window.bigEndian) { msg.append(contentsOf: $0) }
        if let flag { msg.append(flag) }
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)).prefix(6))
    }

    // MARK: zones

    private func tick() {
        advertise() // picks up the next token when the 5-minute window turns over
        scan()
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

    private var lastStatus = ""

    private func writeStatus() {
        guard Date().timeIntervalSince(lastWrite) > 2 else { return }
        lastWrite = Date()
        let state = central.map { "\($0.state.rawValue)" } ?? "none"
        let auth = CBManager.authorization.rawValue
        let text = "bluetooth=\(state) (5=on) auth=\(auth) (3=allowed) scanning=\(central?.isScanning ?? false) " +
            "heard=\(heardAny) ours=\(heardOurs) rssi=\(rssi.map { String(Int($0)) } ?? "-") zone=\(zone) " +
            "advertising=\(peripheral?.isAdvertising ?? false) phone=\(phoneVerdict.map { "\($0.near ? "near" : "away") \(Int(-$0.at.timeIntervalSinceNow))s ago" } ?? "-") phoneRSSI=\(phoneRSSI.map(String.init) ?? "-")\n"
        // Only written when the state changes (the counters alone don't count)
        let key = text.replacingOccurrences(of: #"heard=\d+ ours=\d+ "#, with: "", options: .regularExpression)
        guard key != lastStatus else { return }
        lastStatus = key
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hop/near-status.txt")
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func evaluate() {
        // The phone's own verdict wins while it's fresh: it hears the Mac far better than the Mac hears it,
        // and it has already smoothed the readings, so act on it straight away
        if let v = phoneVerdict, Date().timeIntervalSince(v.at) < 30 {
            set(v.near ? .near : .far)
            return
        }
        if let away = advertAway, Date().timeIntervalSince(away) < 30 {
            set(.far)
            return
        }
        let target = targetZone()
        guard target != zone else { pending = nil; return }
        if pending?.zone != target { pending = (target, Date()) }
        // Open quickly when the phone arrives, close slowly when it leaves, so a passing blip never does either
        let wait: TimeInterval = target == .near ? 1.0 : 2.5
        if let p = pending, Date().timeIntervalSince(p.since) >= wait { set(target) }
    }

    private func targetZone() -> Zone {
        guard let r = rssi else { return .far }
        // A little hysteresis so it does not flicker right at the line
        return r >= nearThreshold - (zone == .near ? 5 : 0) ? .near : .far
    }

    private func set(_ z: Zone) {
        pending = nil
        guard z != zone else { return }
        zone = z
        onZone(z)
    }
}
