import AVFoundation
import CoreMedia
import Foundation

/// Talks to scrcpy's on-phone server directly (protocol of scrcpy 3.x), so Hop can draw the phone in its
/// own window. Video is H.264 decoded by the Mac's hardware; audio is raw PCM; control messages carry input.
final class PhoneStream {
    struct Config {
        var serial: String
        var adb: String
        var serverJar: String
        var serverVersion: String
        var wireless: Bool
        /** Dock mode: the phone opens a separate desktop-sized display (e.g. "1920x1200/200") and streams that
            instead of its own screen, which stays usable on the phone. */
        var newDisplay: String? = nil
        /** No picture or sound: a quiet background connection that keeps the clipboards in sync. */
        var controlOnly = false
    }

    var serial: String { config.serial }

    /// Called on the main queue.
    var onFormat: (CMVideoFormatDescription, CGSize) -> Void = { _, _ in }
    var onFrame: (CMSampleBuffer) -> Void = { _ in }
    var onClipboard: (String) -> Void = { _ in }
    var onEnded: (String?) -> Void = { _ in }

    private let config: Config
    private var server: Process?
    private var port: UInt16 = 0
    private var video: BlockingSocket?
    private var audio: BlockingSocket?
    private var control: BlockingSocket?
    private let controlQueue = DispatchQueue(label: "hop.control")
    private var format: CMVideoFormatDescription?
    private var stopped = false
    private let player = PCMPlayer()

    init(config: Config) { self.config = config }

    // MARK: lifecycle

    func start() {
        Thread.detachNewThread { [self] in
            do {
                try connect()
                if !config.controlOnly {
                    Thread.detachNewThread { [self] in runVideo() }
                    Thread.detachNewThread { [self] in runAudio() }
                }
                Thread.detachNewThread { [self] in
                    runControlReader()
                    if config.controlOnly { finish(stopped ? nil : "The phone disconnected.") }
                }
            } catch {
                finish("Couldn't start the phone screen (\(error)).")
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        video?.close(); audio?.close(); control?.close()
        server?.terminate()
        player.stop()
        let port = port
        if port != 0 { _ = try? Self.run(config.adb, ["-s", config.serial, "forward", "--remove", "tcp:\(port)"]) }
    }

    private func finish(_ error: String?) {
        let wasStopped = stopped
        stop()
        if !wasStopped { DispatchQueue.main.async { self.onEnded(error) } }
    }

    private func connect() throws {
        let adb = config.adb, serial = config.serial
        // Only send the helper program when the phone doesn't already have this exact one (saves time over Wi-Fi)
        let localSize = (try? FileManager.default.attributesOfItem(atPath: config.serverJar)[.size] as? NSNumber)?.intValue ?? -1
        let remoteSize = Int((try? Self.run(adb, ["-s", serial, "shell", "stat", "-c", "%s", "/data/local/tmp/scrcpy-server.jar"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -2
        if localSize != remoteSize {
            _ = try Self.run(adb, ["-s", serial, "push", config.serverJar, "/data/local/tmp/scrcpy-server.jar"])
        }

        let scid = String(format: "%08x", UInt32.random(in: 1...0x7fffffff))
        port = UInt16.random(in: 27200...27999)
        _ = try Self.run(adb, ["-s", serial, "forward", "tcp:\(port)", "localabstract:scrcpy_\(scid)"])

        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        let options: [String]
        if config.controlOnly {
            options = ["video=false", "audio=false", "stay_awake=false", "power_off_on_close=false"]
        } else {
            // Over Wi-Fi (often shared and busy) a smaller, steadier stream feels faster than a sharp, stuttering one,
            // and uncompressed sound alone is 1.5 Mbps, so it stays on the phone (which is right beside the Mac)
            var o = ["video_bit_rate=\(config.wireless ? 2_500_000 : 16_000_000)", "max_fps=60"]
            o += config.wireless ? ["audio=false"] : ["audio_codec=raw"]
            if let display = config.newDisplay {
                o += ["new_display=\(display)", "max_size=\(config.wireless ? 1600 : 0)", "stay_awake=false", "power_off_on_close=false"]
            } else {
                o += ["max_size=\(config.wireless ? 1280 : 2340)", "stay_awake=true", "power_off_on_close=true"]
            }
            options = o
        }
        p.arguments = ["-s", serial, "shell", "CLASSPATH=/data/local/tmp/scrcpy-server.jar", "app_process", "/",
                       "com.genymobile.scrcpy.Server", config.serverVersion,
                       "scid=\(scid)", "log_level=info", "tunnel_forward=true"] + options
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in self?.finish(nil) }
        try p.run()
        server = p

        // The server needs a moment to listen; the forwarded port accepts right away, so wait for its first byte
        var first: BlockingSocket?
        for _ in 0..<100 where first == nil {
            if let s = try? BlockingSocket(port: port), (try? s.read(1)) != nil { first = s } else { Thread.sleep(forTimeInterval: 0.1) }
        }
        guard let v = first else { throw StreamError.timeout }
        if config.controlOnly {
            // A single socket in this mode, which carries the device name first
            control = v
            _ = try v.read(64)
            return
        }
        video = v
        if !config.wireless { audio = try BlockingSocket(port: port) } // no sound socket over Wi-Fi
        control = try BlockingSocket(port: port)
        _ = try v.read(64) // device name
    }

    // MARK: video

    private func runVideo() {
        guard let s = video else { return }
        do {
            let codec = try s.readU32()
            guard codec == 0x6832_3634 else { throw StreamError.unsupported } // "h264"
            _ = try s.read(8) // initial width, height; the config packet carries the real ones
            while !stopped {
                let ptsFlags = try s.readU64()
                let size = Int(try s.readU32())
                let packet = try s.read(size)
                if ptsFlags & (1 << 63) != 0 { handleConfig(packet) } else { handleFrame(packet) }
            }
        } catch {
            finish(stopped ? nil : "The phone screen disconnected.")
        }
    }

    private func handleConfig(_ data: Data) {
        let nals = Self.splitAnnexB(data)
        guard let sps = nals.first(where: { ($0.first ?? 0) & 0x1f == 7 }),
              let pps = nals.first(where: { ($0.first ?? 0) & 0x1f == 8 }) else { return }
        var desc: CMVideoFormatDescription?
        sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
        }
        guard let desc else { return }
        format = desc
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let size = CGSize(width: Int(dims.width), height: Int(dims.height))
        DispatchQueue.main.async { self.onFormat(desc, size) }
    }

    private func handleFrame(_ data: Data) {
        guard let format else { return }
        // Annex B start codes -> 4-byte lengths, which is what Core Media expects
        var avcc = Data()
        for nal in Self.splitAnnexB(data) {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }
        guard !avcc.isEmpty else { return }
        var block: CMBlockBuffer?
        let count = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) }
        var sample: CMSampleBuffer?
        var sizes = [count]
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &sizes, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        DispatchQueue.main.async { self.onFrame(sample) }
    }

    static func splitAnnexB(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var starts: [(at: Int, len: Int)] = []
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0 {
                if b[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 4 <= b.count, b[i + 2] == 0, b[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        if starts.isEmpty { return b.isEmpty ? [] : [data] }
        return starts.enumerated().compactMap { idx, s in
            let from = s.at + s.len
            let to = idx + 1 < starts.count ? starts[idx + 1].at : b.count
            return to > from ? Data(b[from..<to]) : nil
        }
    }

    // MARK: audio (raw 48 kHz stereo 16-bit)

    private func runAudio() {
        guard let s = audio else { return }
        do {
            let codec = try s.readU32()
            guard codec == 0x0072_6177 else { return } // "raw"; 0 means the phone can't share audio
            player.start()
            while !stopped {
                let ptsFlags = try s.readU64()
                let packet = try s.read(Int(try s.readU32()))
                if ptsFlags & (1 << 63) == 0 { player.play(packet) }
            }
        } catch {}
    }

    // MARK: control

    private func runControlReader() {
        guard let s = control else { return }
        // Device -> Mac messages: only clipboard changes matter to us
        while !stopped {
            guard let type = try? s.read(1).first else { return }
            switch type {
            case 0: // clipboard
                guard let len = try? s.readU32(), let text = try? s.read(Int(len)) else { return }
                if let str = String(data: text, encoding: .utf8) { DispatchQueue.main.async { self.onClipboard(str) } }
            case 1: // ack of our set-clipboard
                _ = try? s.read(8)
            case 2: // uhid output
                guard let head = try? s.read(4) else { return }
                _ = try? s.read(Int(head[2]) << 8 | Int(head[3]))
            default:
                return
            }
        }
    }

    private func send(_ msg: Data) {
        controlQueue.async { [weak self] in try? self?.control?.write(msg) }
    }

    enum TouchAction: UInt8 { case down = 0, up = 1, move = 2 }

    func touch(_ action: TouchAction, at p: CGPoint, screen: CGSize) {
        var m = Data([2, action.rawValue])
        m.appendBE(UInt64.max - 1) // generic finger
        m.appendPosition(p, screen)
        m.appendBE(UInt16(action == .up ? 0 : 0xffff))
        m.appendBE(UInt32(0)); m.appendBE(UInt32(0))
        send(m)
    }

    func scroll(at p: CGPoint, screen: CGSize, dx: CGFloat, dy: CGFloat) {
        func fp(_ v: CGFloat) -> UInt16 { UInt16(bitPattern: Int16(max(-1, min(1, v / 16)) * 32767)) }
        var m = Data([3])
        m.appendPosition(p, screen)
        m.appendBE(fp(dx)); m.appendBE(fp(dy))
        m.appendBE(UInt32(0))
        send(m)
    }

    /// Android keycodes: 3 home, 4 back, 24/25 volume, 26 power, 66 enter, 67 delete, 187 recent apps.
    func key(_ keycode: UInt32) {
        for action: UInt8 in [0, 1] {
            var m = Data([0, action])
            m.appendBE(keycode); m.appendBE(UInt32(0)); m.appendBE(UInt32(0))
            send(m)
        }
    }

    func text(_ s: String) {
        let utf8 = Data(s.utf8.prefix(300))
        var m = Data([1])
        m.appendBE(UInt32(utf8.count))
        m.append(utf8)
        send(m)
    }

    func setClipboard(_ s: String, paste: Bool) {
        let utf8 = Data(s.utf8)
        var m = Data([9])
        m.appendBE(UInt64(0))
        m.append(paste ? 1 : 0)
        m.appendBE(UInt32(utf8.count))
        m.append(utf8)
        send(m)
    }

    /// Copies files straight to the phone's Downloads/Hop over the debugging connection (no Hop link needed).
    func push(_ urls: [URL]) {
        let adb = config.adb, serial = config.serial
        DispatchQueue.global().async {
            _ = try? Self.run(adb, ["-s", serial, "shell", "mkdir", "-p", "/sdcard/Download/Hop"])
            for url in urls where !url.hasDirectoryPath {
                _ = try? Self.run(adb, ["-s", serial, "push", url.path, "/sdcard/Download/Hop/"])
            }
        }
    }

    func expandNotifications() { send(Data([5])) }
    /// Turns the phone's own display off or on; mirroring keeps working either way.
    func setDisplay(on: Bool) { send(Data([10, on ? 1 : 0])) }

    // MARK: helpers

    enum StreamError: Error { case timeout, unsupported }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        var be = v.bigEndian
        append(Data(bytes: &be, count: MemoryLayout<T>.size))
    }

    mutating func appendPosition(_ p: CGPoint, _ screen: CGSize) {
        appendBE(Int32(p.x)); appendBE(Int32(p.y))
        appendBE(UInt16(screen.width)); appendBE(UInt16(screen.height))
    }
}

/// Minimal blocking TCP socket to 127.0.0.1 (the adb forward), read on its own thread.
final class BlockingSocket {
    private let fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r != 0 { Darwin.close(fd); throw PhoneStream.StreamError.timeout }
    }

    func read(_ n: Int) throws -> Data {
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress! + got, n - got, 0) }
            if r <= 0 { throw PhoneStream.StreamError.timeout }
            got += r
        }
        return Data(buf)
    }

    func readU32() throws -> UInt32 { try read(4).reduce(0) { $0 << 8 | UInt32($1) } }
    func readU64() throws -> UInt64 { try read(8).reduce(0) { $0 << 8 | UInt64($1) } }

    func write(_ d: Data) throws {
        try d.withUnsafeBytes { raw in
            var sent = 0
            while sent < d.count {
                let r = Darwin.send(fd, raw.baseAddress! + sent, d.count - sent, 0)
                if r <= 0 { throw PhoneStream.StreamError.timeout }
                sent += r
            }
        }
    }

    func close() { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
}

/// Plays the phone's raw audio with a small buffer so sound stays in sync with the picture.
final class PCMPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var queued = 0
    private let lock = NSLock()

    func start() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try? engine.start()
        node.play()
    }

    func stop() { node.stop(); engine.stop() }

    func play(_ pcm: Data) {
        let frames = pcm.count / 4
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        lock.lock()
        let backlog = queued
        lock.unlock()
        if backlog > 48_000 / 5 { return } // more than 200 ms behind: drop to catch up
        buffer.frameLength = AVAudioFrameCount(frames)
        let l = buffer.floatChannelData![0], r = buffer.floatChannelData![1]
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                l[i] = Float(Int16(littleEndian: s[2 * i])) / 32768
                r[i] = Float(Int16(littleEndian: s[2 * i + 1])) / 32768
            }
        }
        lock.lock(); queued += frames; lock.unlock()
        node.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queued -= frames; self.lock.unlock()
        }
    }
}
