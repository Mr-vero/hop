// An original soundtrack for the showcase video, synthesised from scratch (no samples, no licences needed).
// Timed to the edit: soft cold open (0–4 s), upbeat demo (4–44.4 s), hushed security section (44.4–54.4 s),
// full finish and outro (54.4–59.5 s).
//   swiftc -O music.swift -o music && ./music soundtrack.wav
import Foundation

let SR = 44100.0, LEN = 59.5
let N = Int(SR * LEN)
var L = [Float](repeating: 0, count: N), R = [Float](repeating: 0, count: N)

let bpm = 112.0, beat = 60 / bpm, bar = beat * 4
let demoStart = 4.0, secStart = 44.4, finStart = 54.4

func add(_ i: Int, _ v: Double, pan: Double = 0) {
    guard i >= 0 && i < N else { return }
    L[i] += Float(v * (1 - max(0, pan)))
    R[i] += Float(v * (1 + min(0, pan)))
}
var rng: UInt64 = 0x9E3779B97F4A7C15
func noise() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(Int64(bitPattern: rng >> 1) % 2_000_000) / 1_000_000 - 1 }

/// Detuned saw pad through a gentle low-pass, slow attack and release.
func pad(_ freqs: [Double], _ t0: Double, _ t1: Double, amp: Double, cutoff: Double = 1400) {
    let i0 = Int(t0 * SR), i1 = Int((t1 + 1.4) * SR)
    var lpL = 0.0, lpR = 0.0
    let a = 1 - exp(-2 * .pi * cutoff / SR)
    var phases = [Double](repeating: 0, count: freqs.count * 2)
    for i in max(0, i0)..<min(N, i1) {
        let t = Double(i) / SR - t0
        let env = min(1, t / 0.7) * (Double(i) / SR > t1 ? exp(-(Double(i) / SR - t1) / 0.5) : 1)
        var sL = 0.0, sR = 0.0
        for (k, f) in freqs.enumerated() {
            for d in 0..<2 {
                let idx = k * 2 + d
                phases[idx] += f * (d == 0 ? 0.997 : 1.003) / SR
                phases[idx] -= floor(phases[idx])
                let saw = 2 * phases[idx] - 1
                if d == 0 { sL += saw } else { sR += saw }
            }
        }
        lpL += a * (sL - lpL); lpR += a * (sR - lpR)
        let g = amp * env / Double(freqs.count)
        add(i, lpL * g, pan: -0.0); R[i] += Float((lpR - lpL) * g * 0.6)
    }
}

/// A soft bell-like pluck.
func pluck(_ f: Double, _ t0: Double, amp: Double, pan: Double = 0, decay: Double = 0.45) {
    let i0 = Int(t0 * SR)
    for j in 0..<Int(SR * decay * 4) {
        let t = Double(j) / SR
        let env = exp(-t / decay) * min(1, t / 0.004)
        let v = sin(2 * .pi * f * t) + 0.35 * sin(2 * .pi * f * 2 * t) * exp(-t / (decay * 0.4)) + 0.12 * sin(2 * .pi * f * 3.01 * t) * exp(-t / (decay * 0.25))
        add(i0 + j, v * env * amp, pan: pan)
    }
}

func bass(_ f: Double, _ t0: Double, _ dur: Double, amp: Double) {
    let i0 = Int(t0 * SR)
    for j in 0..<Int(SR * (dur + 0.1)) {
        let t = Double(j) / SR
        let env = min(1, t / 0.01) * (t > dur ? exp(-(t - dur) / 0.04) : 1) * (0.75 + 0.25 * exp(-t / 0.15))
        let v = tanh(1.6 * (sin(2 * .pi * f * t) + 0.25 * sin(2 * .pi * 2 * f * t)))
        add(i0 + j, v * env * amp)
    }
}

func kick(_ t0: Double, amp: Double) {
    let i0 = Int(t0 * SR); var ph = 0.0
    for j in 0..<Int(SR * 0.45) {
        let t = Double(j) / SR
        let f = 45 + 95 * exp(-t / 0.035)
        ph += f / SR
        add(i0 + j, sin(2 * .pi * ph) * exp(-t / 0.18) * amp)
    }
}

func hat(_ t0: Double, amp: Double, pan: Double = 0.25) {
    let i0 = Int(t0 * SR); var prev = 0.0
    for j in 0..<Int(SR * 0.08) {
        let t = Double(j) / SR
        let n = noise(); let hp = n - prev; prev = n
        add(i0 + j, hp * exp(-t / 0.018) * amp, pan: pan)
    }
}

func clap(_ t0: Double, amp: Double) {
    let i0 = Int(t0 * SR); var bp1 = 0.0, bp2 = 0.0
    for j in 0..<Int(SR * 0.3) {
        let t = Double(j) / SR
        bp1 += 0.25 * (noise() - bp1); bp2 += 0.6 * (bp1 - bp2)
        let env = exp(-t / 0.09) * (t < 0.01 ? 1.3 : 1)
        add(i0 + j, (bp1 - bp2) * env * amp * 3)
    }
}

/// Filtered noise that opens up: a riser into a section.
func riser(_ t0: Double, _ t1: Double, amp: Double) {
    var lp = 0.0
    for i in Int(t0 * SR)..<min(N, Int(t1 * SR)) {
        let p = (Double(i) / SR - t0) / (t1 - t0)
        let a = 1 - exp(-2 * .pi * (200 + 5000 * p * p) / SR)
        lp += a * (noise() - lp)
        add(i, lp * amp * p * p, pan: sin(p * 20) * 0.3)
    }
}

func boom(_ t0: Double, amp: Double) {
    let i0 = Int(t0 * SR); var ph = 0.0
    for j in 0..<Int(SR * 2.2) {
        let t = Double(j) / SR
        ph += (38 + 30 * exp(-t / 0.3)) / SR
        add(i0 + j, sin(2 * .pi * ph) * exp(-t / 0.9) * amp)
    }
}

// MARK: - harmony: C – G – Am – F, warm and optimistic

let chords: [[Double]] = [[130.81, 164.81, 196.00, 261.63], [123.47, 146.83, 196.00, 246.94], [130.81, 164.81, 220.00, 261.63], [130.81, 174.61, 220.00, 261.63]]
let roots: [Double] = [65.41, 49.00, 55.00, 43.65]
let arps: [[Double]] = [[523.25, 659.25, 783.99, 659.25], [493.88, 587.33, 783.99, 587.33], [523.25, 659.25, 880.00, 659.25], [523.25, 698.46, 880.00, 698.46]]

// cold open: a pad swells, a pluck for each word, a riser into the drop
pad(chords[0].map { $0 * 0.5 }, 0.0, 4.0, amp: 0.22, cutoff: 700)
for (i, tm) in [0.3, 1.1, 2.0].enumerated() { pluck([783.99, 880.0, 1046.5][i], tm, amp: 0.16, pan: [-0.3, 0.3, 0][i], decay: 0.8) }
riser(2.2, 4.0, amp: 0.10)
boom(demoStart, amp: 0.55)

// the demo: four-on-the-floor, bass, arpeggio and pads
var tm = demoStart
var barIndex = 0
while tm < secStart - 0.01 {
    let c = barIndex % 4
    let full = barIndex >= 2               // drums settle in after the title
    pad(chords[c], tm, tm + bar, amp: 0.16, cutoff: barIndex < 2 ? 900 : 1500)
    for b in 0..<4 {
        let bt = tm + Double(b) * beat
        guard bt < secStart else { break }
        if full || b == 0 { kick(bt, amp: 0.55) }
        if full && (b == 1 || b == 3) { clap(bt, amp: 0.11) }
        bass(roots[c] * (b == 2 ? 2 : 1), bt, beat * 0.85, amp: 0.20)
        for h in 0..<2 where full { hat(bt + Double(h) * beat / 2 + beat / 4, amp: 0.05, pan: h == 0 ? 0.25 : -0.25) }
        if barIndex >= 1 {
            for e in 0..<2 {
                let note = arps[c][(b * 2 + e) % 4]
                pluck(note, bt + Double(e) * beat / 2, amp: 0.07, pan: e == 0 ? -0.35 : 0.35, decay: 0.32)
            }
        }
    }
    tm += bar; barIndex += 1
}

// security: drums drop out, low pulse and glassy bells, a sense of calm and trust
riser(secStart - 1.2, secStart, amp: 0.05)
var st = secStart
var sb = 0
while st < finStart - 0.01 {
    let c = [2, 3, 0, 1][sb % 4]
    pad(chords[c].map { $0 * 0.5 }, st, min(finStart, st + bar), amp: 0.2, cutoff: 800)
    for b in 0..<8 {
        let bt = st + Double(b) * beat / 2
        guard bt < finStart else { break }
        bass(roots[c], bt, beat * 0.3, amp: 0.10)                       // heartbeat-like low pulse
        if b % 2 == 0 { pluck(arps[c][(b / 2) % 4] * 2, bt, amp: 0.05, pan: b % 4 == 0 ? -0.5 : 0.5, decay: 0.9) }
    }
    st += bar; sb += 1
}
riser(finStart - 2.0, finStart, amp: 0.12)
boom(finStart, amp: 0.6)

// finish: everything back for the recap, then a final chord that rings out
var ft = finStart
var fb = 0
while ft < 58.0 {
    let c = fb % 4
    pad(chords[c], ft, ft + bar, amp: 0.18, cutoff: 1700)
    for b in 0..<4 {
        let bt = ft + Double(b) * beat
        guard bt < 58.0 else { break }
        kick(bt, amp: 0.55); if b == 1 || b == 3 { clap(bt, amp: 0.12) }
        bass(roots[c] * (b == 2 ? 2 : 1), bt, beat * 0.85, amp: 0.2)
        for h in 0..<2 { hat(bt + Double(h) * beat / 2 + beat / 4, amp: 0.05, pan: h == 0 ? 0.25 : -0.25) }
        for e in 0..<2 { pluck(arps[c][(b * 2 + e) % 4], bt + Double(e) * beat / 2, amp: 0.07, pan: e == 0 ? -0.35 : 0.35, decay: 0.32) }
    }
    ft += bar; fb += 1
}
pad(chords[0] + [523.25], 58.0, 59.0, amp: 0.22, cutoff: 1800)
kick(58.0, amp: 0.5)
for (i, f) in [523.25, 659.25, 783.99, 1046.5].enumerated() { pluck(f, 58.0 + Double(i) * 0.06, amp: 0.09, pan: Double(i) * 0.2 - 0.3, decay: 1.2) }

// MARK: - space (a stereo delay) and mastering

let d = Int(beat * 0.75 * SR)
for i in d..<N {
    L[i] += R[i - d] * 0.22
    R[i] += L[i - d] * 0.22
}
// fade out at the very end, gentle limiter, normalise
for i in 0..<N {
    let t = Double(i) / SR
    let fade = t > LEN - 1.2 ? max(0, (LEN - t) / 1.2) : 1
    L[i] = Float(tanh(Double(L[i]) * 1.2) * fade); R[i] = Float(tanh(Double(R[i]) * 1.2) * fade)
}
let peak = max(L.map { abs($0) }.max()!, R.map { abs($0) }.max()!)
let gain = 0.89 / peak

// write 16-bit stereo WAV
var data = Data()
func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
data.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + N * 4)); data.append("WAVE".data(using: .ascii)!)
data.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(2); u32(UInt32(SR)); u32(UInt32(SR) * 4); u16(4); u16(16)
data.append("data".data(using: .ascii)!); u32(UInt32(N * 4))
var pcm = [Int16](repeating: 0, count: N * 2)
for i in 0..<N { pcm[2 * i] = Int16(max(-1, min(1, L[i] * gain)) * 32767); pcm[2 * i + 1] = Int16(max(-1, min(1, R[i] * gain)) * 32767) }
pcm.withUnsafeBytes { data.append(contentsOf: $0) }
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "soundtrack.wav"))
print("wrote soundtrack, \(LEN) s")
