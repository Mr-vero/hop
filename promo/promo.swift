// Renders Hop's promo video (1080x1920, 30 fps) frame by frame with Core Graphics and encodes it to H.264.
//   swiftc -O promo.swift -o promo && ./promo out.mp4            whole video
//   ./promo --stills 3,9.5,13 dir                                 PNG stills at those seconds (for checking)
import AppKit
import AVFoundation
import CoreText

let W = 1080.0, H = 1920.0, FPS = 30.0, DUR = 36.0
let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconImage: CGImage = {
    let url = here.appendingPathComponent("../art/icon-1024.png")
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}()

// MARK: - easing

func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, x)) }
func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func easeIn(_ x: Double) -> Double { x * x * x }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func back(_ x: Double) -> Double { let c = 1.70158, c3 = c + 1; return 1 + c3 * pow(x - 1, 3) + c * pow(x - 1, 2) }
func mix(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }
/// 0→1 over [a, a+d], 1 until b, then 1→0 over [b, b+d].
func window(_ t: Double, _ a: Double, _ b: Double, _ d: Double = 0.35) -> Double { min(easeOut(prog(t, a, a + d)), 1 - easeIn(prog(t, b, b + d))) }

// MARK: - colours

func rgb(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
let violet = rgb(0x8A5CFF), blue = rgb(0x3D6BFF), cyan = rgb(0x00C6FF), green = rgb(0x34D399), red = rgb(0xFF5B5B)
let white = rgb(0xFFFFFF), ink2 = rgb(0xA3A7B3)
let accent = [violet, blue, cyan]

// MARK: - drawing helpers (top-left origin)

var ctx: CGContext!

func rr(_ r: CGRect, _ radius: Double) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
}
func fill(_ path: CGPath, _ c: CGColor) { ctx.addPath(path); ctx.setFillColor(c); ctx.fillPath() }
func stroke(_ path: CGPath, _ c: CGColor, _ w: Double) { ctx.addPath(path); ctx.setStrokeColor(c); ctx.setLineWidth(w); ctx.strokePath() }
func gradient(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locs)!
}
func fillGradient(_ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(gradient(colors), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
func glow(_ center: CGPoint, _ radius: Double, _ c: CGColor) {
    ctx.drawRadialGradient(gradient([c, c.copy(alpha: 0)!]), startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}
func shadowed(_ blur: Double, _ alpha: Double, _ y: Double = 20, _ draw: () -> Void) {
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -y), blur: blur, color: rgb(0x000000, alpha)); draw(); ctx.restoreGState()
}
func alpha(_ a: Double, _ draw: () -> Void) {
    guard a > 0.001 else { return }
    ctx.saveGState(); ctx.setAlpha(a); ctx.beginTransparencyLayer(auxiliaryInfo: nil); draw(); ctx.endTransparencyLayer(); ctx.restoreGState()
}
func scaled(_ s: Double, around p: CGPoint, _ draw: () -> Void) {
    ctx.saveGState(); ctx.translateBy(x: p.x, y: p.y); ctx.scaleBy(x: s, y: s); ctx.translateBy(x: -p.x, y: -p.y); draw(); ctx.restoreGState()
}
func icon(_ r: CGRect) {
    ctx.saveGState(); ctx.addPath(rr(r, r.width * 0.23)); ctx.clip()
    // the image is drawn in a flipped context, so flip it back locally
    ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
    // the PNG has transparent margins around the squircle; zoom past them
    let k = 1.22
    ctx.draw(iconImage, in: CGRect(x: -r.width * (k - 1) / 2, y: -r.height * (k - 1) / 2, width: r.width * k, height: r.height * k))
    ctx.restoreGState()
}

func font(_ size: Double, _ weight: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: size, weight: weight) }

@discardableResult
func text(_ s: String, _ size: Double, _ weight: NSFont.Weight = .regular, _ color: CGColor = white,
          x: Double, y: Double, align: NSTextAlignment = .left, maxWidth: Double = 2000, kern: Double = 0) -> CGSize {
    let attrs: [NSAttributedString.Key: Any] = [.font: font(size, weight), .foregroundColor: NSColor(cgColor: color)!, .kern: kern]
    let a = NSAttributedString(string: s, attributes: attrs)
    var sz = a.size()
    if sz.width > maxWidth { sz.width = maxWidth }
    let ox = align == .center ? x - sz.width / 2 : align == .right ? x - sz.width : x
    a.draw(with: CGRect(x: ox, y: y, width: sz.width + 2, height: sz.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    return sz
}

/// A line of text filled with Hop's gradient, centred at x.
func gradText(_ s: String, _ size: Double, _ weight: NSFont.Weight, x: Double, y: Double) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font(size, weight), .kern: -size * 0.02]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    let ascent = font(size, weight).ascender
    ctx.saveGState()
    ctx.translateBy(x: x - w / 2, y: y + ascent)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textMatrix = .identity
    ctx.setTextDrawingMode(.clip)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.drawLinearGradient(gradient(accent), start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: 0), options: [])
    ctx.restoreGState()
}

// MARK: - pieces

func background(_ t: Double) {
    ctx.setFillColor(rgb(0x07080C)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let a = t * 0.35
    glow(CGPoint(x: 540 + 260 * cos(a), y: 520 + 140 * sin(a * 1.3)), 720, rgb(0x8A5CFF, 0.30))
    glow(CGPoint(x: 540 - 280 * cos(a * 0.8), y: 1300 + 160 * sin(a)), 760, rgb(0x00C6FF, 0.20))
    glow(CGPoint(x: 540, y: 980), 900, rgb(0x3D6BFF, 0.12))
}

/// Big caption at the top: title (with optional gradient second line) and a grey subtitle.
func caption(_ t: Double, _ a: Double, _ b: Double, _ l1: String, _ l2: String? = nil, grad2: Bool = true, sub: String? = nil) {
    let v = window(t, a, b, 0.45)
    guard v > 0 else { return }
    let rise = (1 - v) * 40
    alpha(v) {
        let y0 = 250 + rise
        text(l1, 76, .semibold, x: W / 2, y: y0, align: .center, kern: -1.6)
        if let l2 {
            if grad2 { gradText(l2, 76, .semibold, x: W / 2, y: y0 + 88) } else { text(l2, 76, .semibold, x: W / 2, y: y0 + 88, align: .center, kern: -1.6) }
        }
        if let sub { text(sub, 34, .regular, ink2, x: W / 2, y: y0 + (l2 == nil ? 104 : 196), align: .center) }
    }
}

// Mac geometry
let macRect = CGRect(x: 60, y: 760, width: 960, height: 620)
let screenRect = macRect.insetBy(dx: 14, dy: 14)
let notchW = screenRect.width * 0.17, notchH = 26.0

func mac(_ t: Double, content: () -> Void) {
    shadowed(80, 0.6, 40) { fill(rr(macRect, 34), rgb(0x15171E)) }
    stroke(rr(macRect.insetBy(dx: 1, dy: 1), 33), rgb(0x2D3039), 2)
    ctx.saveGState(); ctx.addPath(rr(screenRect, 20)); ctx.clip()
    // wallpaper
    ctx.setFillColor(rgb(0x0E1430)); ctx.fill(screenRect)
    glow(CGPoint(x: screenRect.minX + 150, y: screenRect.minY + 60), 520, rgb(0x5B3BC8, 0.75))
    glow(CGPoint(x: screenRect.maxX - 80, y: screenRect.maxY), 560, rgb(0x0A6FA8, 0.7))
    // menu bar
    ctx.setFillColor(rgb(0x000000, 0.22)); ctx.fill(CGRect(x: screenRect.minX, y: screenRect.minY, width: screenRect.width, height: notchH))
    text("Finder   File   Edit   View", 15, .medium, rgb(0xFFFFFF, 0.85), x: screenRect.minX + 18, y: screenRect.minY + 4)
    content()
    ctx.restoreGState()
    // base
    let base = CGRect(x: macRect.minX - 50, y: macRect.maxY - 2, width: macRect.width + 100, height: 30)
    fillGradient(rr(base, 14), [rgb(0xD5D8E0), rgb(0x8C909A)], from: CGPoint(x: 0, y: base.minY), to: CGPoint(x: 0, y: base.maxY))
    fill(rr(CGRect(x: W / 2 - 70, y: base.minY, width: 140, height: 11), 6), rgb(0x7C818B))
}

func menubarRight(_ s: String, highlight: Double = 0) {
    let x = screenRect.maxX - 18
    if highlight > 0 {
        let w = 108.0
        fill(rr(CGRect(x: x - w - 70, y: screenRect.minY + 3, width: w, height: 20), 6), rgb(0x3D6BFF, highlight))
        text(s, 15, .semibold, white, x: x - 70 - w / 2, y: screenRect.minY + 4, align: .center, kern: 1.5)
    }
    text("Wi-Fi   9:41", 15, .medium, rgb(0xFFFFFF, 0.85), x: x, y: screenRect.minY + 4, align: .right)
}

enum Island { case closed, connecting, notif, typing(String), sent, call, answered, clip, code, file }

/// The notch island at the top of the Mac's screen. `open` 0…1 animates the size.
func island(_ kind: Island, open: Double, width: Double, height: Double, theme: CGColor = blue) {
    let w = mix(notchW, width, open), h = mix(notchH, height, open)
    let r = CGRect(x: W / 2 - w / 2, y: screenRect.minY, width: w, height: h)
    let path = CGMutablePath()
    let rad = min(28, h / 2)
    path.move(to: CGPoint(x: r.minX, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - rad, y: r.maxY), radius: rad)
    path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - rad), radius: rad)
    path.closeSubpath()
    shadowed(30, 0.5 * open, 10) { fill(path, rgb(0x000000)) }
    if open > 0.05 {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        glow(CGPoint(x: r.minX + 40, y: r.minY), w * 0.8, theme.copy(alpha: 0.35 * open)!)
        ctx.restoreGState()
        stroke(path, theme.copy(alpha: 0.85 * open)!, 2)
    }
    let c = open > 0.6 ? (open - 0.6) / 0.4 : 0
    guard c > 0 else { return }
    alpha(c) {
        let cy = r.maxY - 46.0, x0 = r.minX + 26
        switch kind {
        case .connecting:
            icon(CGRect(x: x0, y: cy - 20, width: 40, height: 40))
            text("Connecting to Galaxy…", 21, .semibold, x: x0 + 56, y: cy - 13)
            spinner(CGPoint(x: r.maxX - 44, y: cy))
        case .notif, .typing, .sent:
            fillGradient(rr(CGRect(x: x0, y: cy - 34, width: 54, height: 54), 14), [rgb(0x25D366), rgb(0x128C7E)], from: CGPoint(x: x0, y: cy - 34), to: CGPoint(x: x0 + 54, y: cy + 20))
            text("MESSAGES · NOW", 13, .semibold, rgb(0xFFFFFF, 0.5), x: x0 + 70, y: cy - 38, kern: 0.8)
            text("Mum", 21, .semibold, x: x0 + 70, y: cy - 20)
            if case .typing(let s) = kind {
                fill(rr(CGRect(x: x0 + 70, y: cy + 6, width: w - 190, height: 34), 10), rgb(0xFFFFFF, 0.12))
                let sz = text(s, 18, .regular, x: x0 + 82, y: cy + 12)
                if Int(t * 2) % 2 == 0 { ctx.setFillColor(white); ctx.fill(CGRect(x: x0 + 84 + sz.width, y: cy + 13, width: 2, height: 21)) }
            } else if case .sent = kind {
                text("Reply sent ✓", 18, .medium, green, x: x0 + 70, y: cy + 8)
            } else {
                text("Dinner at 7? Bring the bread 🍞", 18, .regular, rgb(0xFFFFFF, 0.78), x: x0 + 70, y: cy + 8)
            }
            roundButton(CGPoint(x: r.maxX - 76, y: cy - 4), 20, rgb(0xFFFFFF, 0.15), symbol: "arrowshape.turn.up.left.fill")
            roundButton(CGPoint(x: r.maxX - 32, y: cy - 4), 20, rgb(0xFFFFFF, 0.15), symbol: "xmark")
        case .call, .answered:
            symbolImage("phone.badge.waveform.fill", size: 34, color: green, center: CGPoint(x: x0 + 22, y: cy))
            text("Sarah", 23, .semibold, x: x0 + 58, y: cy - 26)
            text(kindIsAnswered(kind) ? "On a call on your phone" : "Incoming call", 18, .regular, rgb(0xFFFFFF, 0.7), x: x0 + 58, y: cy + 2)
            if !kindIsAnswered(kind) {
                roundButton(CGPoint(x: r.maxX - 104, y: cy), 26, red, symbol: "phone.down.fill")
                roundButton(CGPoint(x: r.maxX - 44, y: cy), 26, green, symbol: "phone.fill")
            }
        case .clip:
            icon(CGRect(x: x0, y: cy - 22, width: 44, height: 44))
            text("Copied from phone", 21, .semibold, x: x0 + 60, y: cy - 24)
            text("Order #48213 · track your parcel", 17, .regular, rgb(0xFFFFFF, 0.75), x: x0 + 60, y: cy + 2)
        case .code:
            icon(CGRect(x: x0, y: cy - 22, width: 44, height: 44))
            text("Code 482 913 copied", 21, .semibold, x: x0 + 60, y: cy - 24)
            text("From your bank · press ⌘V", 17, .regular, rgb(0xFFFFFF, 0.75), x: x0 + 60, y: cy + 2)
        case .file:
            icon(CGRect(x: x0, y: cy - 20, width: 40, height: 40))
            text("Sending Boarding pass.pdf", 21, .semibold, x: x0 + 56, y: cy - 13)
        case .closed: break
        }
    }
}
func kindIsAnswered(_ k: Island) -> Bool { if case .answered = k { return true }; return false }

var t = 0.0
func spinner(_ c: CGPoint) {
    ctx.saveGState(); ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: t * 7)
    let p = CGMutablePath(); p.addArc(center: .zero, radius: 13, startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
    ctx.addPath(p); ctx.setStrokeColor(white); ctx.setLineWidth(3.5); ctx.setLineCap(.round); ctx.strokePath()
    ctx.restoreGState()
}

func symbolImage(_ name: String, size: Double, color: CGColor, center: CGPoint) {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .semibold).applying(.init(paletteColors: [NSColor(cgColor: color)!]))) else { return }
    var r = CGRect(origin: .zero, size: img.size)
    guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return }
    let w = Double(img.size.width), h = Double(img.size.height)
    ctx.saveGState(); ctx.translateBy(x: center.x - w / 2, y: center.y + h / 2); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); ctx.restoreGState()
}

func roundButton(_ c: CGPoint, _ r: Double, _ color: CGColor, symbol: String) {
    fill(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil), color)
    symbolImage(symbol, size: r * 0.8, color: white, center: c)
}

/// A phone screen's wallpaper and icons.
func phoneScreen(_ r: CGRect, radius: Double, clock: Bool = true) {
    ctx.saveGState(); ctx.addPath(rr(r, radius)); ctx.clip()
    ctx.setFillColor(rgb(0x1B1F6E)); ctx.fill(r)
    glow(CGPoint(x: r.minX + r.width * 0.2, y: r.minY + r.height * 0.1), r.height * 0.6, rgb(0xFF8A5C, 0.9))
    glow(CGPoint(x: r.maxX, y: r.maxY), r.height * 0.6, rgb(0x00C6FF, 0.85))
    glow(CGPoint(x: r.midX, y: r.midY), r.height * 0.5, rgb(0x6B4DFF, 0.6))
    if clock {
        text("9:41", r.width * 0.25, .light, x: r.midX, y: r.minY + r.height * 0.1, align: .center)
    }
    let cols = 4, gap = r.width * 0.07, size = (r.width - gap * 5) / 4
    for i in 0..<8 {
        let x = r.minX + gap + Double(i % cols) * (size + gap)
        let y = r.maxY - gap * 1.6 - Double(2 - i / cols) * (size + gap)
        fill(rr(CGRect(x: x, y: y, width: size, height: size), size * 0.28), rgb(0xFFFFFF, i % 3 == 0 ? 0.34 : 0.22))
    }
    ctx.restoreGState()
}

/// The physical phone lying beside the Mac.
func physicalPhone(_ r: CGRect, content: ((CGRect) -> Void)? = nil) {
    shadowed(40, 0.6, 18) { fill(rr(r, r.width * 0.16), rgb(0x2A2D35)) }
    fillGradient(rr(r, r.width * 0.16), [rgb(0xC9CCD3), rgb(0x6D717B)], from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.maxX, y: r.maxY))
    let glass = r.insetBy(dx: 6, dy: 6)
    fill(rr(glass, glass.width * 0.14), rgb(0x000000))
    let s = glass.insetBy(dx: 5, dy: 5)
    if let content { content(s) } else { phoneScreen(s, radius: s.width * 0.12) }
    fill(CGPath(ellipseIn: CGRect(x: s.midX - 5, y: s.minY + 9, width: 10, height: 10), transform: nil), rgb(0x000000))
}

/// The phone window on the Mac's screen.
func phoneWindow(_ r: CGRect) {
    shadowed(40, 0.6, 20) { fill(rr(r, r.width * 0.14), rgb(0x000000)) }
    stroke(rr(r, r.width * 0.14), rgb(0xFFFFFF, 0.16), 1.5)
    phoneScreen(r.insetBy(dx: 7, dy: 7), radius: r.width * 0.12)
    // hover toolbar
    let tb = CGRect(x: r.midX - 56, y: r.minY - 34, width: 112, height: 24)
    fill(rr(tb, 12), rgb(0x2A2C36, 0.9))
    for i in 0..<4 { fill(CGPath(ellipseIn: CGRect(x: tb.minX + 14 + Double(i) * 24, y: tb.midY - 5, width: 10, height: 10), transform: nil), rgb(0xFFFFFF, 0.6)) }
}

func cursor(_ p: CGPoint, click: Double = 0) {
    if click > 0 && click < 1 {
        let rr2 = 10 + 30 * click
        stroke(CGPath(ellipseIn: CGRect(x: p.x - rr2, y: p.y - rr2, width: 2 * rr2, height: 2 * rr2), transform: nil), rgb(0xFFFFFF, 0.8 * (1 - click)), 3)
    }
    let path = CGMutablePath()
    path.move(to: p)
    path.addLine(to: CGPoint(x: p.x, y: p.y + 34))
    path.addLine(to: CGPoint(x: p.x + 9, y: p.y + 26))
    path.addLine(to: CGPoint(x: p.x + 16, y: p.y + 41))
    path.addLine(to: CGPoint(x: p.x + 22, y: p.y + 38))
    path.addLine(to: CGPoint(x: p.x + 15, y: p.y + 24))
    path.addLine(to: CGPoint(x: p.x + 26, y: p.y + 23))
    path.closeSubpath()
    shadowed(8, 0.5, 3) { fill(path, rgb(0x000000)) }
    ctx.addPath(path); ctx.setStrokeColor(white); ctx.setLineWidth(2.5); ctx.setLineJoin(.round); ctx.strokePath()
}

func lerpPoint(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint { CGPoint(x: mix(a.x, b.x, p), y: mix(a.y, b.y, p)) }

func badge(_ c: CGPoint, symbol: String, title: String, v: Double) {
    alpha(v) {
        scaled(mix(0.7, 1, back(v)), around: c) {
            let r = CGRect(x: c.x - 150, y: c.y - 150, width: 300, height: 300)
            fill(rr(r, 60), rgb(0xFFFFFF, 0.05))
            stroke(rr(r, 60), rgb(0xFFFFFF, 0.12), 2)
            symbolImage(symbol, size: 92, color: white, center: CGPoint(x: c.x, y: c.y - 30))
            text(title, 32, .semibold, x: c.x, y: c.y + 62, align: .center)
        }
    }
}

// MARK: - the timeline

func frame(_ time: Double) {
    t = time
    background(t)

    // 1. intro: icon pops, two words
    let introOut = 1 - easeIn(prog(t, 2.7, 3.2))
    if t < 3.3 {
        alpha(introOut) {
            let p = back(prog(t, 0.1, 0.8))
            let c = CGPoint(x: W / 2, y: 760)
            scaled(0.4 + 0.6 * p, around: c) {
                glow(c, 420, rgb(0x3D6BFF, 0.35 * p))
                shadowed(60, 0.6, 20) { icon(CGRect(x: c.x - 150, y: c.y - 150, width: 300, height: 300)) }
            }
            let a1 = easeOut(prog(t, 0.7, 1.1)), a2 = easeOut(prog(t, 1.3, 1.7))
            alpha(a1) { text("Android + Mac", 84, .semibold, x: W / 2, y: 1000 + (1 - a1) * 30, align: .center, kern: -1.8) }
            alpha(a2) { gradText("finally friends.", 84, .semibold, x: W / 2, y: 1100 + (1 - a2) * 30) }
        }
    }

    // captions per scene
    caption(t, 3.3, 4.8, "iPhone users get", "all the magic.", grad2: false, sub: "Notifications, calls, AirDrop, Mirroring…")
    caption(t, 5.0, 6.2, "Now your", "Android does too.")
    caption(t, 6.6, 11.2, "Bring it near.", sub: "Your phone appears on your Mac.")
    caption(t, 11.6, 16.2, "Notifications", "in the notch.", sub: "Reply without picking it up.")
    caption(t, 16.6, 19.8, "Calls, too.", sub: "Answer right from your Mac.")
    caption(t, 20.2, 23.4, "One clipboard.", sub: "Copy on one. Paste on the other.")
    caption(t, 23.8, 26.6, "Codes,", "already copied.", sub: "Bank codes land on your Mac.")
    caption(t, 27.0, 30.2, "Drop files.", "Go full desktop.", sub: "Drag onto the phone · Dock mode")
    caption(t, 30.6, 32.8, "Private", "by design.")

    // 2–8: the Mac
    let macIn = easeOut(prog(t, 3.4, 4.1)), macOut = easeIn(prog(t, 30.3, 30.9))
    let macV = macIn * (1 - macOut)
    if macV > 0 {
        alpha(macV) {
            ctx.saveGState(); ctx.translateBy(x: 0, y: (1 - macIn) * 120 + macOut * 160)
            drawMacScene()
            ctx.restoreGState()
        }
    }

    // 9. privacy badges
    if t > 30.6 && t < 33.4 {
        let out = 1 - easeIn(prog(t, 32.9, 33.3))
        badge(CGPoint(x: 230, y: 980), symbol: "lock.fill", title: "Encrypted", v: easeOut(prog(t, 30.8, 31.3)) * out)
        badge(CGPoint(x: 540, y: 1260), symbol: "icloud.slash.fill", title: "No cloud", v: easeOut(prog(t, 31.1, 31.6)) * out)
        badge(CGPoint(x: 850, y: 980), symbol: "chevron.left.forwardslash.chevron.right", title: "Open source", v: easeOut(prog(t, 31.4, 31.9)) * out)
    }

    // 10. outro
    if t > 33.2 {
        let p = back(prog(t, 33.3, 34.0)), a = easeOut(prog(t, 33.3, 33.8))
        let c = CGPoint(x: W / 2, y: 700)
        alpha(a) {
            glow(c, 460, rgb(0x3D6BFF, 0.35))
            scaled(0.5 + 0.5 * p, around: c) { shadowed(60, 0.6, 20) { icon(CGRect(x: c.x - 130, y: c.y - 130, width: 260, height: 260)) } }
        }
        let a1 = easeOut(prog(t, 33.7, 34.2)), a2 = easeOut(prog(t, 34.0, 34.5)), a3 = easeOut(prog(t, 34.3, 34.8))
        alpha(a1) { text("Hop", 120, .bold, x: W / 2, y: 880 + (1 - a1) * 30, align: .center, kern: -3) }
        alpha(a2) { text("Your Android, right in your Mac's notch.", 36, .regular, ink2, x: W / 2, y: 1030, align: .center) }
        alpha(a3) {
            let pill = CGRect(x: W / 2 - 230, y: 1130, width: 460, height: 76)
            fill(rr(pill, 38), white)
            text("Free · Open source", 32, .semibold, rgb(0x0B0C10), x: W / 2, y: 1149, align: .center)
            text("mr-vero.github.io/hop", 34, .medium, x: W / 2, y: 1260, align: .center)
            text("macOS · Android", 26, .regular, ink2, x: W / 2, y: 1316, align: .center)
        }
    }
}

// Phone positions
let deskPhoneRest = CGRect(x: 800, y: 1450, width: 190, height: 400)
let windowRect = CGRect(x: screenRect.maxX - 250, y: screenRect.minY + 70, width: 222, height: 470)

func drawMacScene() {
    // physical phone slides up beside the Mac (scene 3), stays until 27
    let slide = easeOut(prog(t, 6.8, 7.8)), leave = easeIn(prog(t, 26.6, 27.2))
    let phoneR = deskPhoneRest.offsetBy(dx: (1 - slide) * 300 + leave * 300, dy: (1 - slide) * 200)

    // phone window appears at 9.4, leaves in dock mode at 28.4
    let winIn = back(prog(t, 9.4, 10.0)), winOut = easeIn(prog(t, 28.3, 28.7))
    let dock = easeInOut(prog(t, 28.5, 29.2))

    mac(t) {
        // desktop windows
        alpha(1 - dock) {
            for (i, r) in [CGRect(x: screenRect.minX + 40, y: screenRect.minY + 70, width: 440, height: 130),
                           CGRect(x: screenRect.minX + 40, y: screenRect.minY + 220, width: 360, height: 130),
                           CGRect(x: screenRect.minX + 40, y: screenRect.minY + 370, width: 440, height: 130)].enumerated() {
                fill(rr(r, 16), rgb(0xFFFFFF, 0.06))
                stroke(rr(r, 16), rgb(0xFFFFFF, 0.08), 1.5)
                // Notes window gets the pasted text in the clipboard scene
                if i == 0 {
                    text("Notes", 18, .semibold, rgb(0xFFFFFF, 0.6), x: r.minX + 20, y: r.minY + 16)
                    let paste = easeOut(prog(t, 22.2, 22.5))
                    alpha(paste) { text("Order #48213 · track your parcel", 22, .regular, x: r.minX + 20, y: r.minY + 56) }
                }
            }
        }
        // dock mode desktop
        if dock > 0 {
            alpha(dock) {
                ctx.setFillColor(rgb(0x14163A)); ctx.fill(screenRect.insetBy(dx: 0, dy: notchH))
                glow(CGPoint(x: screenRect.minX + 200, y: screenRect.minY + 120), 600, rgb(0x6B4DFF, 0.6))
                glow(CGPoint(x: screenRect.maxX, y: screenRect.maxY), 500, rgb(0x00C6FF, 0.5))
                let k = easeOut(prog(t, 28.9, 29.5))
                for (i, r) in [CGRect(x: screenRect.minX + 60, y: screenRect.minY + 70, width: 420, height: 330),
                               CGRect(x: screenRect.minX + 400, y: screenRect.minY + 130, width: 440, height: 330)].enumerated() {
                    alpha(k) {
                        let rr3 = r.offsetBy(dx: 0, dy: (1 - k) * 40 * Double(i + 1))
                        fill(rr(rr3, 14), rgb(0x1E2130, 0.95)); stroke(rr(rr3, 14), rgb(0xFFFFFF, 0.12), 1.5)
                        fill(rr(CGRect(x: rr3.minX, y: rr3.minY, width: rr3.width, height: 34), 14), rgb(0xFFFFFF, 0.06))
                        text(i == 0 ? "Messages" : "Chrome", 16, .semibold, rgb(0xFFFFFF, 0.8), x: rr3.minX + 16, y: rr3.minY + 8)
                        for j in 0..<4 { fill(rr(CGRect(x: rr3.minX + 20, y: rr3.minY + 56 + Double(j) * 56, width: rr3.width - 40 - Double(j % 2) * 80, height: 36), 10), rgb(0xFFFFFF, 0.07)) }
                    }
                }
                let tb = CGRect(x: screenRect.minX, y: screenRect.maxY - 54, width: screenRect.width, height: 54)
                ctx.setFillColor(rgb(0x000000, 0.4)); ctx.fill(tb)
                for i in 0..<6 { fill(rr(CGRect(x: W / 2 - 150 + Double(i) * 52, y: tb.minY + 11, width: 32, height: 32), 9), rgb(0xFFFFFF, i == 0 ? 0.5 : 0.3)) }
                text("Dock mode", 15, .semibold, rgb(0xFFFFFF, 0.7), x: screenRect.minX + 20, y: tb.minY + 17)
            }
        }
        // menu bar code
        let codeHi = window(t, 24.6, 26.4, 0.3)
        menubarRight("482 913", highlight: codeHi)
        if codeHi <= 0 { menubarRight("") }

        // phone window grows out of the island
        if winIn > 0 && winOut < 1 {
            let p = winIn * (1 - winOut)
            let anchor = CGPoint(x: W / 2, y: screenRect.minY + 10)
            ctx.saveGState()
            let s = max(0.05, p)
            ctx.translateBy(x: mix(anchor.x, windowRect.midX, p), y: mix(anchor.y, windowRect.midY, p))
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -windowRect.midX, y: -windowRect.midY)
            alpha(clamp(p * 1.4)) { phoneWindow(windowRect) }
            ctx.restoreGState()
        }

        // files dragged onto the phone window, drawn above it
        drawDrag()
        // the island
        drawIsland()

        // cursor for reply and answer
        cursorScenes()
    }

    // physical phone and its signal rings
    if slide > 0 && leave < 1 {
        if t > 7.3 && t < 9.6 {
            for k in 0..<3 {
                let ph = ((t - 7.3) * 0.7 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                let rad = 60 + 260 * ph
                stroke(CGPath(ellipseIn: CGRect(x: phoneR.midX - rad, y: phoneR.midY - rad, width: 2 * rad, height: 2 * rad), transform: nil), rgb(0x00C6FF, 0.7 * (1 - ph)), 3)
            }
        }
        physicalPhone(phoneR) { s in
            phoneScreen(s, radius: s.width * 0.12, clock: t < 20.0 || t > 26.4)
            // copy popup on the phone (clipboard scene)
            let copy = window(t, 20.4, 21.8, 0.25)
            if copy > 0 {
                alpha(copy) {
                    let b = CGRect(x: s.minX + 12, y: s.minY + 120, width: s.width - 24, height: 76)
                    fill(rr(b, 14), rgb(0xFFFFFF, 0.92))
                    text("Order #48213", 17, .semibold, rgb(0x111111), x: b.minX + 12, y: b.minY + 12)
                    text("track your parcel", 15, .regular, rgb(0x444444), x: b.minX + 12, y: b.minY + 40)
                    let pop = CGRect(x: s.midX - 40, y: b.minY - 44, width: 80, height: 34)
                    fill(rr(pop, 10), rgb(0x2B2D35))
                    text("Copy", 16, .semibold, x: pop.midX, y: pop.minY + 7, align: .center)
                }
            }
            // incoming SMS (codes scene)
            let sms = window(t, 23.9, 25.6, 0.3)
            if sms > 0 {
                alpha(sms) {
                    let b = CGRect(x: s.minX + 10, y: s.minY + 40 + (1 - sms) * -30, width: s.width - 20, height: 100)
                    fill(rr(b, 16), rgb(0x262A36, 0.96))
                    text("Your bank · now", 13, .medium, rgb(0xFFFFFF, 0.6), x: b.minX + 12, y: b.minY + 10)
                    text("Your code is", 15, .regular, x: b.minX + 12, y: b.minY + 32)
                    text("482913", 22, .bold, cyan, x: b.minX + 12, y: b.minY + 54, kern: 2)
                }
            }
        }
        // the copied text flies from the phone to the Mac
        let fly = prog(t, 21.6, 22.3)
        if fly > 0 && fly < 1 {
            let p = lerpPoint(CGPoint(x: phoneR.midX, y: phoneR.minY + 150), CGPoint(x: screenRect.minX + 260, y: screenRect.minY + 130), easeInOut(fly))
            let chip = CGRect(x: p.x - 90, y: p.y - 22, width: 180, height: 44)
            shadowed(20, 0.5, 8) { fillGradient(rr(chip, 22), accent, from: CGPoint(x: chip.minX, y: 0), to: CGPoint(x: chip.maxX, y: 0)) }
            text("Order #48213", 18, .semibold, x: p.x, y: chip.minY + 10, align: .center)
        }
    }
}


func drawDrag() {
    guard t > 26.6 && t < 28.6 else { return }
    let drag = easeInOut(prog(t, 27.2, 27.9))
    let start = CGPoint(x: screenRect.minX + 560, y: screenRect.minY + 420), end = CGPoint(x: windowRect.midX - 34, y: windowRect.midY - 40)
    let p = lerpPoint(start, end, drag)
    let drop = easeIn(prog(t, 27.95, 28.15))
    alpha(1 - drop) {
        scaled(1 - 0.6 * drop, around: CGPoint(x: p.x + 34, y: p.y + 40)) {
            shadowed(16, 0.5, 8) { fillGradient(rr(CGRect(x: p.x, y: p.y, width: 68, height: 84), 12), [rgb(0xFF8A5C), rgb(0xFF5B9B)], from: p, to: CGPoint(x: p.x + 68, y: p.y + 84)) }
            text("PDF", 16, .bold, x: p.x + 34, y: p.y + 52, align: .center)
        }
    }
    cursor(CGPoint(x: p.x + 40, y: p.y + 50), click: prog(t, 27.15, 27.4))
}

func drawIsland() {
    // (start, end, kind, width, height, theme)
    let states: [(Double, Double, Island, Double, Double, CGColor)] = [
        (8.0, 9.3, .connecting, 470, 96, blue),
        (12.0, 13.4, .notif, 640, 128, blue),
        (13.4, 15.0, .typing(typed(t, 13.6, 14.8, "On my way! 🍞")), 640, 128, blue),
        (15.0, 15.9, .sent, 640, 128, green),
        (16.9, 18.4, .call, 560, 110, green),
        (18.4, 19.4, .answered, 560, 110, green),
        (22.3, 23.3, .clip, 560, 110, blue),
        (24.7, 26.2, .code, 560, 110, blue),
        (28.0, 28.5, .file, 520, 96, blue),
    ]
    for (i, s) in states.enumerated() {
        let (a, b, kind, w, h, theme) = s
        guard t >= a - 0.01 && t <= b + 0.45 else { continue }
        // consecutive states share the island; only animate open/close at the ends of a run
        let chainedIn = i > 0 && abs(states[i - 1].1 - a) < 0.01
        let chainedOut = i + 1 < states.count && abs(states[i + 1].0 - b) < 0.01
        if t > b && chainedOut { continue }
        let openP = chainedIn ? 1 : back(prog(t, a, a + 0.45))
        let closeP = chainedOut ? 0 : easeIn(prog(t, b, b + 0.35))
        island(kind, open: clamp(openP * (1 - closeP), 0, 1.2), width: w, height: h, theme: theme)
        return
    }
    island(.closed, open: 0, width: 0, height: 0)
}

func typed(_ t: Double, _ a: Double, _ b: Double, _ s: String) -> String {
    let n = Int(Double(s.count) * prog(t, a, b))
    return String(s.prefix(n))
}

func cursorScenes() {
    let replyBtn = CGPoint(x: W / 2 + 320 - 76, y: screenRect.minY + 128 - 50)
    let answerBtn = CGPoint(x: W / 2 + 280 - 44, y: screenRect.minY + 110 - 46)
    if t > 12.4 && t < 14.0 {
        let p = lerpPoint(CGPoint(x: W / 2 + 120, y: screenRect.minY + 380), replyBtn, easeInOut(prog(t, 12.5, 13.2)))
        cursor(p, click: prog(t, 13.25, 13.6))
    }
    if t > 17.3 && t < 18.9 {
        let p = lerpPoint(CGPoint(x: W / 2 + 60, y: screenRect.minY + 380), answerBtn, easeInOut(prog(t, 17.4, 18.0)))
        cursor(p, click: prog(t, 18.1, 18.45))
    }
}

// MARK: - output

func render(to pixelBuffer: CVPixelBuffer, time: Double) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let c = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: Int(W), height: Int(H), bitsPerComponent: 8,
                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    draw(in: c, time: time)
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
}

func draw(in c: CGContext, time: Double) {
    c.translateBy(x: 0, y: H)
    c.scaleBy(x: 1, y: -1)
    ctx = c
    let ns = NSGraphicsContext(cgContext: c, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    frame(time)
    NSGraphicsContext.restoreGraphicsState()
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--stills", args.count >= 3 {
    let times = args[1].split(separator: ",").compactMap { Double($0) }
    let dir = URL(fileURLWithPath: args[2])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for tm in times {
        let c = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        draw(in: c, time: tm)
        let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
        try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(String(format: "t%05.1f.png", tm)))
    }
    exit(0)
}

let out = URL(fileURLWithPath: args.first ?? "Hop-promo.mp4")
try? FileManager.default.removeItem(at: out)
let writer = try! AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                      AVVideoExpectedSourceFrameRateKey: FPS],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(W), kCVPixelBufferHeightKey as String: Int(H),
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
let frames = Int(DUR * FPS)
for i in 0..<frames {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    render(to: pb!, time: Double(i) / FPS)
    adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(FPS)))
    if i % 90 == 0 { print("frame \(i)/\(frames)") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "wrote \(out.path)" : "failed: \(String(describing: writer.error))")
