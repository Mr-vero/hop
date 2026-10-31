// Hop's promo film: a 3D animated short (1920x1080, 30 fps) rendered with SceneKit, with screens drawn in Core
// Graphics and titles composited on top, encoded to H.264.
//   swiftc -O film.swift -o film && ./film Hop-film.mp4          whole film
//   ./film --stills 5,10.5,14 dir                                PNG stills at those seconds (for checking)
import AppKit
import AVFoundation
import CoreText
import SceneKit

let W = 1920.0, H = 1080.0, FPS = 30.0, DUR = 43.0
let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconImage: CGImage = {
    let src = CGImageSourceCreateWithURL(here.appendingPathComponent("../art/icon-1024.png") as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}()

// MARK: - easing

func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, x)) }
func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func easeIn(_ x: Double) -> Double { x * x * x }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
func back(_ x: Double) -> Double { let c = 1.70158, c3 = c + 1; return 1 + c3 * pow(x - 1, 3) + c * pow(x - 1, 2) }
func mix(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }
func window(_ t: Double, _ a: Double, _ b: Double, _ d: Double = 0.35) -> Double { min(easeOut(prog(t, a, a + d)), 1 - easeIn(prog(t, b, b + d))) }
func v3(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 { SCNVector3(x, y, z) }
func mixV(_ a: SCNVector3, _ b: SCNVector3, _ p: Double) -> SCNVector3 {
    v3(mix(Double(a.x), Double(b.x), p), mix(Double(a.y), Double(b.y), p), mix(Double(a.z), Double(b.z), p))
}

// MARK: - 2D drawing helpers (top-left origin, into whichever context `ctx` is)

func rgb(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
let white = rgb(0xFFFFFF), green = rgb(0x34D399), red = rgb(0xFF5B5B), cyan = rgb(0x00C6FF), blue = rgb(0x3D6BFF)
let accent = [rgb(0x8A5CFF), rgb(0x3D6BFF), rgb(0x00C6FF)]
var ctx: CGContext!
var t = 0.0

func rr(_ r: CGRect, _ radius: Double) -> CGPath { CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil) }
func fill(_ p: CGPath, _ c: CGColor) { ctx.addPath(p); ctx.setFillColor(c); ctx.fillPath() }
func stroke(_ p: CGPath, _ c: CGColor, _ w: Double) { ctx.addPath(p); ctx.setStrokeColor(c); ctx.setLineWidth(w); ctx.strokePath() }
func gradient(_ colors: [CGColor]) -> CGGradient { CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)! }
func fillGradient(_ p: CGPath, _ colors: [CGColor], _ a: CGPoint, _ b: CGPoint) {
    ctx.saveGState(); ctx.addPath(p); ctx.clip(); ctx.drawLinearGradient(gradient(colors), start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]); ctx.restoreGState()
}
func glow(_ c: CGPoint, _ r: Double, _ col: CGColor) { ctx.drawRadialGradient(gradient([col, col.copy(alpha: 0)!]), startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: []) }
func shadowed(_ blur: Double, _ a: Double, _ y: Double = 10, _ draw: () -> Void) {
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -y), blur: blur, color: rgb(0, a)); draw(); ctx.restoreGState()
}
func alpha(_ a: Double, _ draw: () -> Void) {
    guard a > 0.002 else { return }
    ctx.saveGState(); ctx.setAlpha(a); ctx.beginTransparencyLayer(auxiliaryInfo: nil); draw(); ctx.endTransparencyLayer(); ctx.restoreGState()
}
func scaled(_ s: Double, _ p: CGPoint, _ draw: () -> Void) {
    ctx.saveGState(); ctx.translateBy(x: p.x, y: p.y); ctx.scaleBy(x: s, y: s); ctx.translateBy(x: -p.x, y: -p.y); draw(); ctx.restoreGState()
}
func icon(_ r: CGRect) {
    ctx.saveGState(); ctx.addPath(rr(r, r.width * 0.23)); ctx.clip()
    ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
    let k = 1.22
    ctx.draw(iconImage, in: CGRect(x: -r.width * (k - 1) / 2, y: -r.height * (k - 1) / 2, width: r.width * k, height: r.height * k))
    ctx.restoreGState()
}
func font(_ s: Double, _ w: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: s, weight: w) }
@discardableResult
func text(_ s: String, _ size: Double, _ weight: NSFont.Weight = .regular, _ color: CGColor = white, x: Double, y: Double,
          align: NSTextAlignment = .left, kern: Double = 0) -> CGSize {
    let a = NSAttributedString(string: s, attributes: [.font: font(size, weight), .foregroundColor: NSColor(cgColor: color)!, .kern: kern])
    let sz = a.size()
    let ox = align == .center ? x - sz.width / 2 : align == .right ? x - sz.width : x
    a.draw(at: CGPoint(x: ox, y: y))
    return sz
}
func gradText(_ s: String, _ size: Double, _ weight: NSFont.Weight, x: Double, y: Double, colors: [CGColor] = accent) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font(size, weight), .kern: -size * 0.02]))
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.saveGState()
    ctx.translateBy(x: x - w / 2, y: y + font(size, weight).ascender); ctx.scaleBy(x: 1, y: -1)
    ctx.textMatrix = .identity; ctx.setTextDrawingMode(.clip); ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.drawLinearGradient(gradient(colors), start: .zero, end: CGPoint(x: w, y: 0), options: [])
    ctx.restoreGState()
}
func symbol(_ name: String, _ size: Double, _ color: CGColor, _ c: CGPoint) {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .semibold).applying(.init(paletteColors: [NSColor(cgColor: color)!]))) else { return }
    var r = CGRect(origin: .zero, size: img.size)
    guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return }
    let w = Double(img.size.width), h = Double(img.size.height)
    ctx.saveGState(); ctx.translateBy(x: c.x - w / 2, y: c.y + h / 2); ctx.scaleBy(x: 1, y: -1); ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); ctx.restoreGState()
}
func roundButton(_ c: CGPoint, _ r: Double, _ col: CGColor, _ sym: String) {
    fill(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil), col)
    symbol(sym, r * 0.8, white, c)
}
func lerpP(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint { CGPoint(x: mix(a.x, b.x, p), y: mix(a.y, b.y, p)) }

/// Draws into a fresh bitmap with a top-left origin and returns it.
func bitmap(_ w: Int, _ h: Int, _ draw: () -> Void) -> CGImage {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: Double(h)); c.scaleBy(x: 1, y: -1)
    let saved = ctx; ctx = c
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState(); ctx = saved
    return c.makeImage()!
}

// MARK: - the Mac's screen (1600x1000 texture)

let SW = 1600.0, SH = 1000.0, menuH = 34.0, notchW = 260.0, notchH = 34.0
let winRect = CGRect(x: SW - 400, y: 120, width: 330, height: 700)

enum Island { case connecting, notif, typing(String), sent, call, answered, clip, code, file }

func phoneScreenArt(_ r: CGRect, radius: Double, clock: Bool = true) {
    ctx.saveGState(); ctx.addPath(rr(r, radius)); ctx.clip()
    ctx.setFillColor(rgb(0x1B1F6E)); ctx.fill(r)
    glow(CGPoint(x: r.minX + r.width * 0.2, y: r.minY + r.height * 0.12), r.height * 0.6, rgb(0xFF8A5C, 0.95))
    glow(CGPoint(x: r.maxX, y: r.maxY), r.height * 0.6, rgb(0x00C6FF, 0.9))
    glow(CGPoint(x: r.midX, y: r.midY), r.height * 0.5, rgb(0x6B4DFF, 0.6))
    if clock {
        text("9:41", r.width * 0.24, .light, x: r.midX, y: r.minY + r.height * 0.09, align: .center)
        text("Friday, 31 October", r.width * 0.05, .medium, rgb(0xFFFFFF, 0.85), x: r.midX, y: r.minY + r.height * 0.09 + r.width * 0.31, align: .center)
    }
    let gap = r.width * 0.07, size = (r.width - gap * 5) / 4
    let colors: [UInt32] = [0x34C759, 0x5AC8FA, 0xFF9500, 0xAF52DE, 0xFF2D55, 0xFFCC00, 0x30B0C7, 0x8E8E93]
    for i in 0..<8 {
        let x = r.minX + gap + Double(i % 4) * (size + gap), y = r.maxY - gap * 1.6 - Double(2 - i / 4) * (size + gap)
        fillGradient(rr(CGRect(x: x, y: y, width: size, height: size), size * 0.28), [rgb(colors[i]), rgb(colors[i], 0.75)],
                     CGPoint(x: x, y: y), CGPoint(x: x + size, y: y + size))
    }
    ctx.restoreGState()
}

func cursor(_ p: CGPoint, click: Double = 0) {
    if click > 0 && click < 1 {
        let r = 12 + 34 * click
        stroke(CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), transform: nil), rgb(0xFFFFFF, 0.85 * (1 - click)), 4)
    }
    let s = 1.5
    let pts: [(Double, Double)] = [(0, 0), (0, 34), (9, 26), (16, 41), (22, 38), (15, 24), (26, 23)]
    let path = CGMutablePath()
    path.move(to: CGPoint(x: p.x, y: p.y))
    for q in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x + q.0 * s, y: p.y + q.1 * s)) }
    path.closeSubpath()
    shadowed(10, 0.5, 4) { fill(path, rgb(0)) }
    ctx.addPath(path); ctx.setStrokeColor(white); ctx.setLineWidth(3); ctx.setLineJoin(.round); ctx.strokePath()
}

func islandArt(_ kind: Island, open: Double, width: Double, height: Double, theme: CGColor) {
    let w = mix(notchW, width, open), h = mix(notchH, height, open)
    let r = CGRect(x: SW / 2 - w / 2, y: 0, width: w, height: h)
    let rad = min(34, h / 2)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: r.minX, y: r.minY)); path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - rad, y: r.maxY), radius: rad)
    path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - rad), radius: rad)
    path.closeSubpath()
    shadowed(40, 0.55 * open, 12) { fill(path, rgb(0)) }
    if open > 0.05 {
        ctx.saveGState(); ctx.addPath(path); ctx.clip(); glow(CGPoint(x: r.minX + 60, y: r.minY), w * 0.8, theme.copy(alpha: 0.4 * open)!); ctx.restoreGState()
        stroke(path, theme.copy(alpha: 0.9 * open)!, 2.5)
    }
    let c = open > 0.6 ? (open - 0.6) / 0.4 : 0
    guard c > 0 else { return }
    alpha(c) {
        let cy = r.maxY - 56, x0 = r.minX + 32
        switch kind {
        case .connecting:
            icon(CGRect(x: x0, y: cy - 25, width: 50, height: 50))
            text("Connecting to Galaxy…", 27, .semibold, x: x0 + 68, y: cy - 17)
            ctx.saveGState(); ctx.translateBy(x: r.maxX - 52, y: cy); ctx.rotate(by: t * 7)
            let p = CGMutablePath(); p.addArc(center: .zero, radius: 15, startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
            ctx.addPath(p); ctx.setStrokeColor(white); ctx.setLineWidth(4); ctx.setLineCap(.round); ctx.strokePath(); ctx.restoreGState()
        case .notif, .typing, .sent:
            fillGradient(rr(CGRect(x: x0, y: cy - 42, width: 66, height: 66), 17), [rgb(0x25D366), rgb(0x128C7E)], CGPoint(x: x0, y: cy - 42), CGPoint(x: x0 + 66, y: cy + 24))
            symbol("message.fill", 30, white, CGPoint(x: x0 + 33, y: cy - 9))
            text("MESSAGES · NOW", 16, .semibold, rgb(0xFFFFFF, 0.5), x: x0 + 86, y: cy - 46, kern: 1)
            text("Mum", 27, .semibold, x: x0 + 86, y: cy - 26)
            if case .typing(let s) = kind {
                fill(rr(CGRect(x: x0 + 86, y: cy + 8, width: w - 240, height: 42), 12), rgb(0xFFFFFF, 0.13))
                let sz = text(s, 23, .regular, x: x0 + 100, y: cy + 15)
                if Int(t * 2.5) % 2 == 0 { ctx.setFillColor(white); ctx.fill(CGRect(x: x0 + 102 + sz.width, y: cy + 16, width: 2.5, height: 27)) }
            } else if case .sent = kind {
                text("Reply sent  ✓", 23, .semibold, green, x: x0 + 86, y: cy + 10)
            } else {
                text("Dinner at 7? Bring the bread 🍞", 23, .regular, rgb(0xFFFFFF, 0.8), x: x0 + 86, y: cy + 10)
            }
            roundButton(CGPoint(x: r.maxX - 92, y: cy - 6), 24, rgb(0xFFFFFF, 0.16), "arrowshape.turn.up.left.fill")
            roundButton(CGPoint(x: r.maxX - 38, y: cy - 6), 24, rgb(0xFFFFFF, 0.16), "xmark")
        case .call, .answered:
            symbol("phone.badge.waveform.fill", 42, green, CGPoint(x: x0 + 26, y: cy))
            text("Sarah", 29, .semibold, x: x0 + 70, y: cy - 32)
            let answered: Bool = { if case .answered = kind { return true }; return false }()
            text(answered ? "On a call on your phone" : "Incoming call", 22, .regular, rgb(0xFFFFFF, 0.72), x: x0 + 70, y: cy + 2)
            if !answered {
                roundButton(CGPoint(x: r.maxX - 128, y: cy), 32, red, "phone.down.fill")
                roundButton(CGPoint(x: r.maxX - 54, y: cy), 32, green, "phone.fill")
            }
        case .clip:
            icon(CGRect(x: x0, y: cy - 27, width: 54, height: 54))
            text("Copied from your phone", 27, .semibold, x: x0 + 72, y: cy - 30)
            text("Pasted where you are", 21, .regular, rgb(0xFFFFFF, 0.72), x: x0 + 72, y: cy + 3)
        case .code:
            icon(CGRect(x: x0, y: cy - 27, width: 54, height: 54))
            text("Code 482 913 copied", 27, .semibold, x: x0 + 72, y: cy - 30)
            text("From your bank · press ⌘V", 21, .regular, rgb(0xFFFFFF, 0.72), x: x0 + 72, y: cy + 3)
        case .file:
            icon(CGRect(x: x0, y: cy - 25, width: 50, height: 50))
            text("Sent Boarding pass.pdf to phone", 27, .semibold, x: x0 + 68, y: cy - 17)
        }
    }
}

func drawIsland() {
    let states: [(Double, Double, Island, Double, Double, CGColor)] = [
        (8.7, 10.0, .connecting, 600, 118, blue),
        (13.1, 14.5, .notif, 820, 156, blue),
        (14.5, 16.1, .typing(typed(t, 14.7, 15.8, "On my way! 🥖")), 820, 156, blue),
        (16.1, 16.9, .sent, 820, 156, green),
        (17.5, 19.0, .call, 700, 136, green),
        (19.0, 20.0, .answered, 700, 136, green),
        (22.6, 23.4, .clip, 680, 136, blue),
        (25.3, 26.3, .code, 680, 136, blue),
        (28.1, 28.8, .file, 680, 118, blue),
    ]
    for (i, s) in states.enumerated() {
        let (a, b, kind, w, h, theme) = s
        guard t >= a - 0.01 && t <= b + 0.45 else { continue }
        let chainedIn = i > 0 && abs(states[i - 1].1 - a) < 0.01
        let chainedOut = i + 1 < states.count && abs(states[i + 1].0 - b) < 0.01
        if t > b && chainedOut { continue }
        let o = (chainedIn ? 1 : back(prog(t, a, a + 0.5))) * (1 - (chainedOut ? 0 : easeIn(prog(t, b, b + 0.35))))
        islandArt(kind, open: clamp(o, 0, 1.2), width: w, height: h, theme: theme)
        return
    }
    fill(rr(CGRect(x: SW / 2 - notchW / 2, y: -20, width: notchW, height: notchH + 20), 16), rgb(0))
}
func typed(_ t: Double, _ a: Double, _ b: Double, _ s: String) -> String { String(s.prefix(Int(Double(s.count) * prog(t, a, b)))) }

func macScreen() -> CGImage {
    bitmap(Int(SW), Int(SH)) {
        // wallpaper
        ctx.setFillColor(rgb(0x0F1433)); ctx.fill(CGRect(x: 0, y: 0, width: SW, height: SH))
        glow(CGPoint(x: 260, y: 80), 900, rgb(0x6A45E0, 0.85))
        glow(CGPoint(x: SW - 100, y: SH), 1000, rgb(0x0A7FBF, 0.8))
        glow(CGPoint(x: SW * 0.55, y: SH * 0.45), 700, rgb(0xFF7A59, 0.25))
        let dock = easeInOut(prog(t, 29.3, 30.1)) * (1 - easeInOut(prog(t, 32.0, 32.6)))
        alpha(1 - dock) {
            // windows
            let notes = CGRect(x: 80, y: 120, width: 640, height: 330)
            shadowed(30, 0.4, 14) { fill(rr(notes, 18), rgb(0x1E2233, 0.92)) }
            fill(rr(CGRect(x: notes.minX, y: notes.minY, width: notes.width, height: 46), 18), rgb(0xFFFFFF, 0.06))
            for i in 0..<3 { fill(CGPath(ellipseIn: CGRect(x: notes.minX + 18 + Double(i) * 22, y: notes.minY + 16, width: 13, height: 13), transform: nil), rgb([0xFF5F57, 0xFEBC2E, 0x28C840][i])) }
            text("Notes", 20, .semibold, rgb(0xFFFFFF, 0.75), x: notes.minX + 100, y: notes.minY + 12)
            text("Weekend plans", 30, .bold, x: notes.minX + 30, y: notes.minY + 72)
            text("• Pick up the bread", 24, .regular, rgb(0xFFFFFF, 0.8), x: notes.minX + 30, y: notes.minY + 124)
            let paste = easeOut(prog(t, 22.45, 22.8))
            alpha(paste) {
                fill(rr(CGRect(x: notes.minX + 22, y: notes.minY + 170, width: 470, height: 44), 10), rgb(0x3D6BFF, 0.25 * (1 - prog(t, 23.2, 24))))
                text("• Order #48213 · track the parcel", 24, .regular, x: notes.minX + 30, y: notes.minY + 176)
            }
            let mail = CGRect(x: 120, y: 500, width: 600, height: 300)
            shadowed(30, 0.4, 14) { fill(rr(mail, 18), rgb(0x1E2233, 0.85)) }
            fill(rr(CGRect(x: mail.minX, y: mail.minY, width: mail.width, height: 46), 18), rgb(0xFFFFFF, 0.06))
            for i in 0..<4 { fill(rr(CGRect(x: mail.minX + 26, y: mail.minY + 74 + Double(i) * 52, width: mail.width - 52 - Double(i % 2) * 120, height: 30), 8), rgb(0xFFFFFF, 0.07)) }
            // the PDF dragged onto the phone window
            if t > 26.9 && t < 28.4 {
                let drag = easeInOut(prog(t, 27.2, 28.0))
                let p = lerpP(CGPoint(x: 820, y: 640), CGPoint(x: winRect.midX - 50, y: winRect.midY - 60), drag)
                let drop = easeIn(prog(t, 28.0, 28.25))
                alpha(1 - drop) {
                    scaled(1 - 0.6 * drop, CGPoint(x: p.x + 50, y: p.y + 62)) {
                        shadowed(20, 0.5, 10) { fillGradient(rr(CGRect(x: p.x, y: p.y, width: 100, height: 124), 16), [rgb(0xFF8A5C), rgb(0xFF4F8B)], p, CGPoint(x: p.x + 100, y: p.y + 124)) }
                        text("PDF", 24, .heavy, x: p.x + 50, y: p.y + 78, align: .center)
                    }
                }
                cursor(CGPoint(x: p.x + 60, y: p.y + 70), click: prog(t, 27.05, 27.35))
            }
        }
        if dock > 0 {
            alpha(dock) {
                ctx.setFillColor(rgb(0x141638)); ctx.fill(CGRect(x: 0, y: menuH, width: SW, height: SH))
                glow(CGPoint(x: 300, y: 200), 900, rgb(0x6B4DFF, 0.6)); glow(CGPoint(x: SW, y: SH), 800, rgb(0x00C6FF, 0.5))
                let k = easeOut(prog(t, 29.7, 30.4))
                for (i, r) in [CGRect(x: 120, y: 110, width: 680, height: 560), CGRect(x: 700, y: 190, width: 720, height: 560)].enumerated() {
                    alpha(k) {
                        let q = r.offsetBy(dx: 0, dy: (1 - k) * 60 * Double(i + 1))
                        shadowed(30, 0.5, 14) { fill(rr(q, 20), rgb(0x1E2130, 0.97)) }
                        fill(rr(CGRect(x: q.minX, y: q.minY, width: q.width, height: 50), 20), rgb(0xFFFFFF, 0.06))
                        text(i == 0 ? "Messages" : "Chrome", 22, .semibold, rgb(0xFFFFFF, 0.85), x: q.minX + 24, y: q.minY + 13)
                        for j in 0..<5 { fill(rr(CGRect(x: q.minX + 28, y: q.minY + 80 + Double(j) * 84, width: q.width - 56 - Double(j % 2) * 140, height: 54), 14), rgb(0xFFFFFF, 0.07)) }
                    }
                }
                let tb = CGRect(x: 0, y: SH - 80, width: SW, height: 80)
                ctx.setFillColor(rgb(0, 0.45)); ctx.fill(tb)
                let cols: [UInt32] = [0xFFFFFF, 0x34C759, 0x5AC8FA, 0xFF9500, 0xAF52DE, 0xFF2D55]
                for i in 0..<6 { fill(rr(CGRect(x: SW / 2 - 200 + Double(i) * 70, y: tb.minY + 16, width: 48, height: 48), 13), rgb(cols[i], i == 0 ? 0.55 : 0.9)) }
                text("Dock mode", 22, .semibold, rgb(0xFFFFFF, 0.75), x: 30, y: tb.minY + 27)
            }
        }
        // menu bar
        ctx.setFillColor(rgb(0, 0.28)); ctx.fill(CGRect(x: 0, y: 0, width: SW, height: menuH))
        text("  Finder    File    Edit    View    Go", 20, .medium, rgb(0xFFFFFF, 0.9), x: 18, y: 5)
        let hi = window(t, 25.3, 26.6, 0.3)
        if hi > 0 {
            fill(rr(CGRect(x: SW - 330, y: 4, width: 130, height: 26), 7), rgb(0x3D6BFF, hi))
            alpha(hi) { text("482 913", 20, .bold, x: SW - 265, y: 5, align: .center, kern: 2) }
        }
        text("Wi-Fi   Fri 9:41", 20, .medium, rgb(0xFFFFFF, 0.9), x: SW - 22, y: 5, align: .right)

        // the phone window springs out of the island, and goes back into it
        let winIn = back(prog(t, 10.0, 10.65)) * (1 - easeIn(prog(t, 29.2, 29.6)))
        let winBack = back(prog(t, 32.4, 33.0)) * (1 - easeIn(prog(t, 33.6, 34.1)))
        let p = t < 31 ? winIn : winBack
        if p > 0.01 {
            let anchor = CGPoint(x: SW / 2, y: 14)
            ctx.saveGState()
            ctx.translateBy(x: mix(anchor.x, winRect.midX, p), y: mix(anchor.y, winRect.midY, p))
            ctx.scaleBy(x: max(0.05, p), y: max(0.05, p))
            ctx.translateBy(x: -winRect.midX, y: -winRect.midY)
            alpha(clamp(p * 1.4)) {
                shadowed(50, 0.6, 24) { fill(rr(winRect, 46), rgb(0)) }
                stroke(rr(winRect, 46), rgb(0xFFFFFF, 0.16), 2)
                phoneScreenArt(winRect.insetBy(dx: 11, dy: 11), radius: 38)
                let tb = CGRect(x: winRect.midX - 80, y: winRect.minY - 48, width: 160, height: 34)
                fill(rr(tb, 17), rgb(0x2A2C36, 0.9))
                let syms = ["xmark", "chevron.backward", "circle", "square.on.square"]
                for (i, s) in syms.enumerated() { symbol(s, 15, rgb(0xFFFFFF, 0.85), CGPoint(x: tb.minX + 26 + Double(i) * 36, y: tb.midY)) }
            }
            ctx.restoreGState()
        }
        drawIsland()
        // cursor for Reply and Answer
        if t > 13.4 && t < 15.0 {
            cursor(lerpP(CGPoint(x: SW / 2 + 200, y: 620), CGPoint(x: SW / 2 + 410 - 92, y: 156 - 62), easeInOut(prog(t, 13.5, 14.2))), click: prog(t, 14.25, 14.6))
        }
        if t > 17.9 && t < 19.4 {
            cursor(lerpP(CGPoint(x: SW / 2 + 100, y: 620), CGPoint(x: SW / 2 + 350 - 54, y: 136 - 56), easeInOut(prog(t, 18.0, 18.6))), click: prog(t, 18.7, 19.05))
        }
    }
}

/// The phone's own screen (600x1290 texture): asleep, home screen, call, copy popup, SMS, dimmed while on the Mac.
func phoneScreen() -> CGImage {
    bitmap(600, 1290) {
        let r = CGRect(x: 0, y: 0, width: 600, height: 1290)
        let wake = easeOut(prog(t, 4.0, 4.6))
        ctx.setFillColor(rgb(0)); ctx.fill(r)
        alpha(wake) {
            phoneScreenArt(r, radius: 70, clock: true)
            // call
            let call = window(t, 17.3, 19.0, 0.25)
            alpha(call) {
                ctx.setFillColor(rgb(0x0B1A12, 0.92)); ctx.fill(r)
                glow(CGPoint(x: 300, y: 400), 500, rgb(0x34D399, 0.35))
                fill(CGPath(ellipseIn: CGRect(x: 220, y: 280, width: 160, height: 160), transform: nil), rgb(0xFFFFFF, 0.15))
                text("S", 80, .semibold, x: 300, y: 310, align: .center)
                text("Sarah", 56, .semibold, x: 300, y: 470, align: .center)
                text("Incoming call", 30, .regular, rgb(0xFFFFFF, 0.7), x: 300, y: 545, align: .center)
                roundButton(CGPoint(x: 160, y: 1060), 62, red, "phone.down.fill")
                roundButton(CGPoint(x: 440, y: 1060), 62, green, "phone.fill")
            }
            // copy popup
            let copy = window(t, 20.8, 22.0, 0.25)
            alpha(copy) {
                let b = CGRect(x: 40, y: 430, width: 520, height: 150)
                fill(rr(b, 26), rgb(0xFFFFFF, 0.95))
                text("Order #48213", 36, .semibold, rgb(0x111111), x: b.minX + 28, y: b.minY + 28)
                text("Track the parcel", 28, .regular, rgb(0x555555), x: b.minX + 28, y: b.minY + 82)
                let pop = CGRect(x: 230, y: b.minY - 90, width: 140, height: 66)
                fill(rr(pop, 18), rgb(0x2B2D35))
                text("Copy", 30, .semibold, x: pop.midX, y: pop.minY + 15, align: .center)
            }
            // SMS
            let sms = window(t, 23.8, 25.6, 0.3)
            alpha(sms) {
                let b = CGRect(x: 26, y: 90 - (1 - sms) * 60, width: 548, height: 200)
                fill(rr(b, 34), rgb(0x262A36, 0.97))
                text("Your bank · now", 26, .medium, rgb(0xFFFFFF, 0.6), x: b.minX + 30, y: b.minY + 24)
                text("Your verification code is", 30, .regular, x: b.minX + 30, y: b.minY + 66)
                text("482913", 48, .bold, cyan, x: b.minX + 30, y: b.minY + 112, kern: 4)
            }
        }
        // the phone's own screen dims while it's shown on the Mac (like iPhone Mirroring), back on when it leaves
        let dim = easeInOut(prog(t, 10.4, 11.0)) * (1 - easeInOut(prog(t, 16.95, 17.3))) + easeInOut(prog(t, 19.2, 19.6)) * (1 - easeInOut(prog(t, 20.5, 20.8)))
            + easeInOut(prog(t, 22.2, 22.6)) * (1 - easeInOut(prog(t, 23.6, 23.8))) + easeInOut(prog(t, 25.8, 26.2)) * (1 - easeInOut(prog(t, 33.9, 34.3)))
        ctx.setFillColor(rgb(0, 0.8 * clamp(dim))); ctx.fill(r)
    }
}

// MARK: - the 3D scene

let scene = SCNScene()
func material(_ color: NSColor, metal: Double = 0, rough: Double = 0.5) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = color
    m.metalness.contents = metal
    m.roughness.contents = rough
    return m
}
func screenMaterial() -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = NSColor.black
    m.isDoubleSided = false
    return m
}
func glowMaterial(_ c: NSColor) -> SCNMaterial {
    let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = c; m.writesToDepthBuffer = false; m.blendMode = .add; return m
}

/// A soft, warm environment for reflections on the aluminium (generated: a studio with a big softbox).
let envImage = bitmap(1024, 512) {
    ctx.setFillColor(rgb(0x14161D)); ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
    glow(CGPoint(x: 300, y: 140), 260, rgb(0xFFE6CC, 0.95))
    glow(CGPoint(x: 780, y: 180), 220, rgb(0x9CC4FF, 0.7))
    fill(rr(CGRect(x: 180, y: 60, width: 260, height: 120), 30), rgb(0xFFF3E6, 0.9))
    ctx.setFillColor(rgb(0x2A2420)); ctx.fill(CGRect(x: 0, y: 300, width: 1024, height: 212))
}
scene.lightingEnvironment.contents = envImage
scene.lightingEnvironment.intensity = 0.85

// background: a dark studio with soft out-of-focus lights, far behind the desk
let backdrop = SCNNode(geometry: SCNPlane(width: 60, height: 30))
backdrop.geometry!.firstMaterial = {
    let m = SCNMaterial(); m.lightingModel = .constant
    m.diffuse.contents = bitmap(2048, 1024) {
        ctx.setFillColor(rgb(0x07080C)); ctx.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
        glow(CGPoint(x: 1024, y: 520), 1100, rgb(0x1C1F3A, 1))
        let lights: [(Double, Double, Double, UInt32, Double)] = [
            (420, 460, 120, 0xFFB46B, 0.35), (640, 380, 70, 0xFFD39A, 0.25), (1500, 420, 140, 0x6B8CFF, 0.3),
            (1720, 520, 90, 0x8A5CFF, 0.28), (1180, 330, 60, 0xFFC27A, 0.2), (260, 600, 90, 0x5AC8FA, 0.18), (1880, 340, 70, 0xFFB46B, 0.22),
        ]
        for l in lights { glow(CGPoint(x: l.0, y: l.1), l.2, rgb(l.3, l.4)) }
    }
    return m
}()
backdrop.position = v3(0, 6, -16)
scene.rootNode.addChildNode(backdrop)

// the desk: warm dark walnut with a gentle reflection
let floor = SCNFloor()
floor.reflectivity = 0.05
floor.reflectionFalloffEnd = 0.9
floor.firstMaterial = material(NSColor(srgbRed: 0.16, green: 0.11, blue: 0.085, alpha: 1), rough: 0.8)
floor.firstMaterial!.diffuse.contents = bitmap(1024, 1024) {
    ctx.setFillColor(rgb(0x2A1C14)); ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    for i in 0..<180 {
        let y = Double(i) * 5.7 + sin(Double(i) * 1.7) * 3
        ctx.setStrokeColor(rgb(i % 3 == 0 ? 0x3A281D : 0x22170F, 0.55)); ctx.setLineWidth(1.5 + Double(i % 4))
        ctx.move(to: CGPoint(x: 0, y: y)); ctx.addCurve(to: CGPoint(x: 1024, y: y + sin(Double(i)) * 8), control1: CGPoint(x: 340, y: y + 6), control2: CGPoint(x: 680, y: y - 6)); ctx.strokePath()
    }
}
floor.firstMaterial!.diffuse.contentsTransform = SCNMatrix4MakeScale(6, 6, 1)
floor.firstMaterial!.diffuse.wrapS = .repeat; floor.firstMaterial!.diffuse.wrapT = .repeat
let floorNode = SCNNode(geometry: floor)
floorNode.categoryBitMask = 2 // the cool rim light skips the desk
scene.rootNode.addChildNode(floorNode)

// MacBook
let aluminium = material(NSColor(srgbRed: 0.74, green: 0.75, blue: 0.78, alpha: 1), metal: 1, rough: 0.42)
let macRoot = SCNNode(); scene.rootNode.addChildNode(macRoot)
let base = SCNNode(geometry: SCNBox(width: 3.0, height: 0.07, length: 2.05, chamferRadius: 0.035))
base.geometry!.firstMaterial = aluminium
base.position = v3(0, 0.035, 0); macRoot.addChildNode(base)
let keyboard = SCNNode(geometry: SCNPlane(width: 2.62, height: 0.95))
keyboard.geometry!.firstMaterial = {
    let m = material(NSColor(white: 0.05, alpha: 1), rough: 0.6)
    m.diffuse.contents = bitmap(1310, 475) {
        ctx.setFillColor(rgb(0x0D0E10)); ctx.fill(CGRect(x: 0, y: 0, width: 1310, height: 475))
        for row in 0..<6 { for col in 0..<14 {
            let w = 1310.0 / 14.6
            fill(rr(CGRect(x: 12 + Double(col) * w * 1.03, y: 10 + Double(row) * 77, width: w - 10, height: 66), 10), rgb(0x1B1C20))
        } }
    }
    return m
}()
keyboard.eulerAngles.x = -.pi / 2; keyboard.position = v3(0, 0.0705, -0.42); macRoot.addChildNode(keyboard)
let trackpad = SCNNode(geometry: SCNPlane(width: 1.05, height: 0.62))
trackpad.geometry!.firstMaterial = material(NSColor(srgbRed: 0.7, green: 0.71, blue: 0.74, alpha: 1), metal: 1, rough: 0.2)
trackpad.eulerAngles.x = -.pi / 2; trackpad.position = v3(0, 0.0706, 0.55); macRoot.addChildNode(trackpad)
let hinge = SCNNode(); hinge.position = v3(0, 0.07, -1.0); hinge.eulerAngles.x = -0.2; macRoot.addChildNode(hinge)
let lid = SCNNode(geometry: SCNBox(width: 3.0, height: 1.96, length: 0.045, chamferRadius: 0.03))
lid.geometry!.firstMaterial = aluminium
lid.position = v3(0, 0.98, -0.0); hinge.addChildNode(lid)
let bezel = SCNNode(geometry: SCNPlane(width: 2.94, height: 1.9))
bezel.geometry!.firstMaterial = material(NSColor(white: 0.02, alpha: 1), rough: 0.15)
bezel.position = v3(0, 0.98, 0.0232); hinge.addChildNode(bezel)
let screenMat = screenMaterial()
let screen = SCNNode(geometry: SCNPlane(width: 2.84, height: 1.775))
screen.geometry!.firstMaterial = screenMat
screen.position = v3(0, 0.985, 0.0236); hinge.addChildNode(screen)

// The phone: the star. Root sits on the desk; `squash` scales around the bottom edge for squash-and-stretch.
let phoneRoot = SCNNode(); scene.rootNode.addChildNode(phoneRoot)
let squash = SCNNode(); phoneRoot.addChildNode(squash)
let titanium = material(NSColor(srgbRed: 0.42, green: 0.43, blue: 0.46, alpha: 1), metal: 0.9, rough: 0.28)
let glassBlack = material(NSColor(white: 0.01, alpha: 1), metal: 0, rough: 0.08)
let body = SCNNode(geometry: SCNBox(width: 0.74, height: 1.58, length: 0.085, chamferRadius: 0.1))
body.geometry!.materials = [glassBlack, titanium, titanium, titanium, titanium, titanium]
body.position = v3(0, 0.79, 0); squash.addChildNode(body)
let phoneMat = screenMaterial()
let phoneScreenNode = SCNNode(geometry: SCNPlane(width: 0.68, height: 1.462))
phoneScreenNode.geometry!.firstMaterial = phoneMat
phoneMat.transparencyMode = .aOne
phoneScreenNode.position = v3(0, 0.79, 0.0435); squash.addChildNode(phoneScreenNode)
// eyes? no: the camera hole, a tiny detail
let cam = SCNNode(geometry: SCNCylinder(radius: 0.022, height: 0.002))
cam.geometry!.firstMaterial = material(NSColor(white: 0.0, alpha: 1), rough: 0.1)
cam.eulerAngles.x = .pi / 2; cam.position = v3(0, 1.48, 0.0446); squash.addChildNode(cam)

// signal rings and light orbs
let rings: [SCNNode] = (0..<3).map { _ in
    let n = SCNNode(geometry: SCNTorus(ringRadius: 1, pipeRadius: 0.012))
    n.geometry!.firstMaterial = glowMaterial(NSColor(srgbRed: 0, green: 0.78, blue: 1, alpha: 1))
    n.opacity = 0; scene.rootNode.addChildNode(n); return n
}
let orbs: [SCNNode] = (0..<18).map { i in
    let n = SCNNode(geometry: SCNSphere(radius: 0.03 + Double(i % 3) * 0.008))
    n.geometry!.firstMaterial = glowMaterial(i % 2 == 0 ? NSColor(srgbRed: 0.35, green: 0.6, blue: 1, alpha: 1) : NSColor(srgbRed: 0.6, green: 0.45, blue: 1, alpha: 1))
    n.opacity = 0; scene.rootNode.addChildNode(n); return n
}
func card(_ label: String, _ sub: String) -> SCNNode {
    let n = SCNNode(geometry: SCNPlane(width: 1.0, height: 0.3))
    let m = SCNMaterial(); m.lightingModel = .constant
    m.diffuse.contents = bitmap(1000, 300) {
        fillGradient(rr(CGRect(x: 4, y: 4, width: 992, height: 292), 146), accent, CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 0))
        icon(CGRect(x: 40, y: 50, width: 200, height: 200))
        text(label, 84, .bold, x: 270, y: 50)
        text(sub, 50, .medium, rgb(0xFFFFFF, 0.85), x: 272, y: 160)
    }
    n.geometry!.firstMaterial = m
    n.constraints = [SCNBillboardConstraint()]
    n.opacity = 0; scene.rootNode.addChildNode(n); return n
}
let clipCard = card("Order #48213", "Copied on phone")
let codeCard = card("482 913", "Your bank code")

// lights: warm key with soft shadows, cool rim, gentle fill
func light(_ type: SCNLight.LightType, _ color: NSColor, _ intensity: Double, at p: SCNVector3, lookAt target: SCNVector3 = v3(0.4, 0.6, 0)) -> SCNLight {
    let l = SCNLight(); l.type = type; l.color = color; l.intensity = intensity
    let n = SCNNode(); n.light = l; n.position = p; n.look(at: target)
    scene.rootNode.addChildNode(n); return l
}
let key = light(.spot, NSColor(srgbRed: 1, green: 0.88, blue: 0.74, alpha: 1), 2600, at: v3(-4.5, 7, 6))
key.spotOuterAngle = 70; key.spotInnerAngle = 30
key.castsShadow = true; key.shadowRadius = 10; key.shadowSampleCount = 24; key.shadowMapSize = CGSize(width: 4096, height: 4096)
key.shadowColor = NSColor(white: 0, alpha: 0.6); key.shadowMode = .forward
let rim = light(.directional, NSColor(srgbRed: 0.55, green: 0.7, blue: 1, alpha: 1), 900, at: v3(3, 4, -7))
rim.categoryBitMask = 1
key.categoryBitMask = 3
let fillL = light(.ambient, NSColor(srgbRed: 0.6, green: 0.62, blue: 0.75, alpha: 1), 180, at: v3(0, 5, 5))

// camera: anamorphic-ish feel with bloom, vignette, gentle depth of field and grading
let camera = SCNCamera()
camera.fieldOfView = 30
camera.zNear = 0.05; camera.zFar = 100
camera.wantsHDR = true
camera.wantsExposureAdaptation = false
camera.exposureOffset = 0.15
camera.bloomIntensity = 0.3; camera.bloomThreshold = 1.0; camera.bloomBlurRadius = 12
camera.vignettingIntensity = 0.55; camera.vignettingPower = 1.1
camera.saturation = 1.08; camera.contrast = 0.08
camera.wantsDepthOfField = true; camera.fStop = 3.2; camera.focalBlurSampleCount = 16; camera.apertureBladeCount = 7
let camNode = SCNNode(); camNode.camera = camera; scene.rootNode.addChildNode(camNode)

let shots: [(Double, SCNVector3, SCNVector3)] = [
    (0.0, v3(0.6, 2.7, 10.8), v3(0.5, 0.9, 0)),
    (3.6, v3(1.4, 2.3, 9.4), v3(1.8, 1.0, 0)),
    (6.6, v3(1.8, 1.6, 6.9), v3(1.7, 0.9, 0.3)),
    (8.6, v3(1.0, 1.6, 6.2), v3(0.9, 0.95, -0.2)),
    (11.2, v3(0.3, 1.42, 4.35), v3(0.08, 1.06, -0.82)),
    (16.9, v3(0.22, 1.40, 4.05), v3(0.06, 1.06, -0.86)),
    (17.7, v3(1.6, 1.3, 5.2), v3(1.3, 0.92, -0.2)),
    (20.5, v3(1.25, 1.6, 6.0), v3(1.0, 1.0, -0.2)),
    (25.6, v3(1.15, 1.65, 6.2), v3(0.95, 1.05, -0.25)),
    (26.6, v3(0.4, 1.45, 4.45), v3(0.1, 1.06, -0.82)),
    (29.2, v3(0.3, 1.45, 4.25), v3(0.06, 1.06, -0.86)),
    (31.8, v3(0.2, 1.95, 7.2), v3(0.4, 0.95, -0.3)),
    (34.4, v3(1.9, 1.75, 7.4), v3(1.2, 0.9, 0)),
    (38.4, v3(-2.6, 2.3, 7.1), v3(0.2, 0.9, -0.2)),
    (43.0, v3(-3.3, 2.9, 7.7), v3(0.2, 1.0, -0.2)),
]
func cameraPose(_ t: Double) -> (SCNVector3, SCNVector3) {
    for i in 0..<(shots.count - 1) where t <= shots[i + 1].0 {
        let p = smooth(prog(t, shots[i].0, shots[i + 1].0))
        return (mixV(shots[i].1, shots[i + 1].1, p), mixV(shots[i].2, shots[i + 1].2, p))
    }
    return (shots.last!.1, shots.last!.2)
}

// MARK: - the phone's performance

/// Where the phone is and how it moves: three hops in, a little turn, a buzz for the call, and hops away.
func phonePose(_ t: Double) -> (x: Double, y: Double, z: Double, sx: Double, sy: Double, lean: Double, yaw: Double) {
    let rest = (x: 2.35, z: 0.35)
    var x = 6.5, z = 0.6, y = 0.0, sx = 1.0, sy = 1.0, lean = 0.0, yaw = -0.35
    // hops in
    let hopsIn: [(Double, Double, Double)] = [(4.3, 6.5, 5.1), (5.0, 5.1, 3.85), (5.7, 3.85, rest.x)]
    // hops away
    let hopsOut: [(Double, Double, Double)] = [(33.1, rest.x, 3.7), (33.8, 3.7, 5.2), (34.5, 5.2, 7.0)]
    let all = hopsIn + hopsOut
    if t < 4.3 { x = 6.5 } else if t > 35.1 { x = 7.0 } else { x = rest.x }
    for (start, from, to) in all {
        let ant = 0.16, air = 0.42, land = 0.22
        if t >= start - ant && t < start {
            let p = prog(t, start - ant, start); x = from; sy = 1 - 0.18 * smooth(p); sx = 1 + 0.12 * smooth(p)
        } else if t >= start && t < start + air {
            let p = prog(t, start, start + air)
            x = mix(from, to, easeInOut(p)); y = 0.6 * sin(.pi * p)
            sy = 1 + 0.12 * sin(.pi * p); sx = 1 - 0.07 * sin(.pi * p)
            lean = (to > from ? -1 : 1) * 0.16 * sin(.pi * p)
        } else if t >= start + air && t < start + air + land {
            let p = prog(t, start + air, start + air + land); x = to
            let k = sin(.pi * p) * (1 - p * 0.3); sy = 1 - 0.16 * k; sx = 1 + 0.1 * k
        }
    }
    z = mix(0.6, rest.z, prog(x, 6.5, rest.x) == 1 ? 1 : 1 - prog(x, rest.x, 6.5))
    // turns to face the Mac after landing, back to the camera when the call comes, away when leaving
    let turn = easeInOut(prog(t, 6.35, 6.9)) * (1 - easeInOut(prog(t, 32.7, 33.0)))
    yaw = mix(-0.15, -0.55, turn)
    // the call: a buzzing jitter
    let buzz = window(t, 17.3, 18.8, 0.1)
    if buzz > 0 { lean += buzz * 0.05 * sin(t * 90); x += buzz * 0.012 * sin(t * 110) }
    // a happy little bounce when the phone appears on the Mac
    let joy = prog(t, 10.1, 10.6)
    if joy > 0 && joy < 1 { let k = sin(.pi * joy); sy *= 1 + 0.08 * k; sx *= 1 - 0.05 * k; y += 0.12 * k }
    // breathing idle
    sy *= 1 + 0.008 * sin(t * 2.6)
    return (x, y, z, sx, sy, lean, yaw)
}

func update(_ t: Double) {
    let (pos, target) = cameraPose(t)
    camNode.position = pos
    camNode.look(at: target)
    let dx = Double(target.x - pos.x), dy = Double(target.y - pos.y), dz = Double(target.z - pos.z)
    camera.focusDistance = CGFloat(sqrt(dx * dx + dy * dy + dz * dz))
    // lights come up at the start, the scene fades down at the end
    let up = easeInOut(prog(t, 0.0, 2.2)), down = 1 - easeInOut(prog(t, 38.6, 39.8))
    key.intensity = 2600 * up * down
    rim.intensity = 900 * up * down
    fillL.intensity = 180 * (0.3 + 0.7 * up) * down

    let p = phonePose(t)
    phoneRoot.position = v3(p.x, p.y, p.z)
    phoneRoot.eulerAngles = SCNVector3(0, p.yaw, p.lean)
    squash.scale = v3(p.sx, p.sy, p.sx)

    screenMat.diffuse.contents = macScreen()
    phoneMat.diffuse.contents = phoneScreen()

    // signal rings spread across the desk from the phone while it says "I'm here"
    for (i, n) in rings.enumerated() {
        let phase = ((t - 7.4) * 0.65 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
        let on = window(t, 7.4, 9.6, 0.3)
        let r = 0.3 + 2.2 * phase
        n.position = v3(p.x, 0.012, p.z); n.scale = v3(r, 1, r)
        n.opacity = CGFloat(on * (1 - phase) * 0.9)
    }
    // the connection: light flows from the phone up into the Mac's screen
    let phoneTop = v3(p.x, 1.2, p.z), macScreenPt = v3(0.3, 1.25, -0.95)
    for (i, n) in orbs.enumerated() {
        let start = 9.1 + Double(i) * 0.045
        let q = prog(t, start, start + 0.8)
        if q > 0 && q < 1 {
            let e = easeInOut(q)
            var v = mixV(phoneTop, macScreenPt, e)
            v.y += CGFloat(0.55 * sin(.pi * e) + 0.06 * sin(Double(i) * 2.1))
            v.z += CGFloat(0.08 * cos(Double(i) * 1.3) * sin(.pi * e))
            n.position = v; n.opacity = CGFloat(sin(.pi * q))
        } else { n.opacity = 0 }
    }
    // clipboard and code cards arc from the phone to the Mac
    func fly(_ n: SCNNode, _ a: Double, _ b: Double, to dest: SCNVector3) {
        let q = prog(t, a, b)
        guard q > 0 && q < 1 else { n.opacity = 0; return }
        let e = easeInOut(q)
        var v = mixV(v3(p.x, 1.1, p.z + 0.1), dest, e); v.y += CGFloat(0.6 * sin(.pi * e))
        n.position = v
        let s = 0.55 * (q < 0.15 ? back(q / 0.15) : 1) * (1 - 0.6 * easeIn(prog(q, 0.75, 1)))
        n.scale = v3(s, s, s)
        n.opacity = CGFloat(min(1, q * 6) * (1 - easeIn(prog(q, 0.85, 1))))
    }
    fly(clipCard, 21.6, 22.55, to: v3(-0.55, 1.55, -0.9))
    fly(codeCard, 24.6, 25.45, to: v3(0.85, 1.9, -1.05))
}

// MARK: - titles over the picture

func titles(_ t: Double) {
    func line(_ a: Double, _ b: Double, _ l1: String, _ l2: String? = nil, grad: Bool = true, y: Double = 860) {
        let v = window(t, a, b, 0.6)
        guard v > 0 else { return }
        // a soft dark band behind the words, so they read over anything
        let bandTop = y < 540 ? 0.0 : y - 140
        ctx.saveGState()
        let band = CGRect(x: 0, y: bandTop, width: W, height: y < 540 ? y + 260 : H - bandTop)
        ctx.clip(to: band)
        let g = gradient(y < 540 ? [rgb(0, 0.55 * v), rgb(0, 0)] : [rgb(0, 0), rgb(0, 0.6 * v)])
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: band.minY), end: CGPoint(x: 0, y: band.maxY), options: [])
        ctx.restoreGState()
        alpha(v) {
            let rise = (1 - v) * 24
            shadowed(30, 0.6, 4) {
                text(l1, 58, .semibold, x: W / 2, y: y + rise, align: .center, kern: -1.2)
                if let l2 {
                    if grad { gradText(l2, 58, .semibold, x: W / 2, y: y + 70 + rise) } else { text(l2, 58, .semibold, x: W / 2, y: y + 70 + rise, align: .center, kern: -1.2) }
                }
            }
        }
    }
    line(0.9, 3.4, "Your Mac and your Android", "have never really talked.", grad: false, y: 110)
    line(4.6, 7.6, "Until now.", y: 900)
    line(9.0, 12.4, "Bring it near.", "It's on your Mac.")
    line(13.0, 16.8, "Notifications in the notch.", "Reply without picking it up.")
    line(17.4, 20.3, "Calls,", "answered from your Mac.")
    line(20.9, 23.5, "One clipboard.", "Both ways.")
    line(23.9, 26.5, "Codes,", "already copied.")
    line(26.9, 29.0, "Drop files", "straight onto your phone.")
    line(29.4, 32.0, "Dock mode.", "Your phone, as a desktop.")
    line(32.6, 35.2, "Walk away,", "and it tucks itself back.")
    // privacy beats
    let pv = window(t, 35.6, 38.4, 0.5)
    if pv > 0 {
        ctx.setFillColor(rgb(0, 0.62 * pv)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        alpha(pv) {
            shadowed(30, 0.6, 4) {
                text("Private by design", 60, .semibold, x: W / 2, y: 380, align: .center, kern: -1.2)
                let items = [("lock.fill", "End-to-end encrypted"), ("icloud.slash.fill", "No cloud, no account"), ("chevron.left.forwardslash.chevron.right", "Open source")]
                for (i, it) in items.enumerated() {
                    let a = easeOut(prog(t, 36.0 + Double(i) * 0.3, 36.5 + Double(i) * 0.3))
                    alpha(a) {
                        let x = W / 2 + Double(i - 1) * 470
                        symbol(it.0, 46, white, CGPoint(x: x, y: 560 + (1 - a) * 20))
                        text(it.1, 32, .medium, rgb(0xFFFFFF, 0.9), x: x, y: 610 + (1 - a) * 20, align: .center)
                    }
                }
            }
        }
    }
    // outro
    if t > 39.2 {
        let a = easeOut(prog(t, 39.3, 39.9)), p = back(prog(t, 39.3, 40.1))
        ctx.setFillColor(rgb(0, 0.86 * easeInOut(prog(t, 38.8, 39.6)))); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        alpha(a) {
            let c = CGPoint(x: W / 2, y: 360)
            glow(c, 380, rgb(0x3D6BFF, 0.4))
            scaled(0.6 + 0.4 * p, c) { shadowed(60, 0.7, 20) { icon(CGRect(x: c.x - 120, y: c.y - 120, width: 240, height: 240)) } }
        }
        let a1 = easeOut(prog(t, 39.8, 40.3)), a2 = easeOut(prog(t, 40.1, 40.6)), a3 = easeOut(prog(t, 40.4, 40.9))
        alpha(a1) { text("Hop", 120, .bold, x: W / 2, y: 520 + (1 - a1) * 24, align: .center, kern: -3) }
        alpha(a2) { gradText("Your Android, right in your Mac's notch.", 44, .medium, x: W / 2, y: 680, colors: [rgb(0xC9B8FF), rgb(0x9CC4FF), rgb(0x8DE8FF)]) }
        alpha(a3) {
            let pill = CGRect(x: W / 2 - 250, y: 780, width: 500, height: 80)
            fill(rr(pill, 40), white)
            text("Free · Open source", 34, .semibold, rgb(0x0B0C10), x: W / 2, y: 799, align: .center)
            text("mr-vero.github.io/hop", 32, .medium, rgb(0xFFFFFF, 0.9), x: W / 2, y: 900, align: .center)
        }
    }
    // fade in from black
    let fadeIn = 1 - easeOut(prog(t, 0, 1.0))
    if fadeIn > 0 { ctx.setFillColor(rgb(0, fadeIn)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H)) }
}

// MARK: - rendering

let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
renderer.scene = scene
renderer.pointOfView = camNode

func renderFrame(_ time: Double, into c: CGContext) {
    t = time
    update(time)
    let img = renderer.snapshot(atTime: time, with: CGSize(width: W, height: H), antialiasingMode: .multisampling4X)
    var r = CGRect(x: 0, y: 0, width: W, height: H)
    let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
    c.saveGState()
    c.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
    c.translateBy(x: 0, y: H); c.scaleBy(x: 1, y: -1)
    ctx = c
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
    titles(time)
    NSGraphicsContext.restoreGraphicsState()
    c.restoreGState()
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--stills", args.count >= 3 {
    let dir = URL(fileURLWithPath: args[2])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for tm in args[1].split(separator: ",").compactMap({ Double($0) }) {
        let c = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        renderFrame(tm, into: c)
        try! NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(String(format: "f%05.1f.png", tm)))
    }
    exit(0)
}

let out = URL(fileURLWithPath: args.first ?? "Hop-film.mp4")
try? FileManager.default.removeItem(at: out)
let writer = try! AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 18_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(W), kCVPixelBufferHeightKey as String: Int(H),
])
writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
let frames = Int(DUR * FPS)
for i in 0..<frames {
    autoreleasepool {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let c = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: Int(W), height: Int(H), bitsPerComponent: 8,
                          bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        renderFrame(Double(i) / FPS, into: c)
        CVPixelBufferUnlockBaseAddress(pb!, [])
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(FPS)))
        if i % 60 == 0 { print("frame \(i)/\(frames)"); fflush(stdout) }
    }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "wrote \(out.path)" : "failed: \(String(describing: writer.error))")
