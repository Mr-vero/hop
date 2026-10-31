// Hop's showcase video: a screen-recording-style demo (1920x1080, 30 fps) of Hop in use, drawn with Core Graphics
// so it's pixel-clean and private (no real screens recorded), with smooth zooms, cursor, keycaps and a phone mockup.
//   swiftc -O showcase.swift -o showcase && ./showcase Hop-showcase.mp4
//   ./showcase --stills 5,11,13 dir
import AppKit
import AVFoundation
import CoreText

let W = 1920.0, H = 1080.0, FPS = 30.0, DUR = 59.5
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
func smoother(_ x: Double) -> Double { x * x * x * (x * (x * 6 - 15) + 10) }
func back(_ x: Double) -> Double { let c = 1.70158, c3 = c + 1; return 1 + c3 * pow(x - 1, 3) + c * pow(x - 1, 2) }
func mix(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }
func window(_ t: Double, _ a: Double, _ b: Double, _ d: Double = 0.35) -> Double { min(easeOut(prog(t, a, a + d)), 1 - easeIn(prog(t, b, b + d))) }
func lerpP(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint { CGPoint(x: mix(a.x, b.x, p), y: mix(a.y, b.y, p)) }

// MARK: - drawing helpers (top-left origin)

func rgb(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
let white = rgb(0xFFFFFF), black = rgb(0x000000), ink = rgb(0x1D1D1F), ink2 = rgb(0x6E6E73)
let green = rgb(0x34C759), red = rgb(0xFF3B30), blue = rgb(0x0A84FF), hopBlue = rgb(0x3D6BFF)
let accent = [rgb(0x8A5CFF), rgb(0x3D6BFF), rgb(0x00C6FF)]
var ctx: CGContext!
var t = 0.0

func rr(_ r: CGRect, _ radius: Double) -> CGPath { CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil) }
func fill(_ p: CGPath, _ c: CGColor) { ctx.addPath(p); ctx.setFillColor(c); ctx.fillPath() }
func fillR(_ r: CGRect, _ c: CGColor) { ctx.setFillColor(c); ctx.fill(r) }
func stroke(_ p: CGPath, _ c: CGColor, _ w: Double) { ctx.addPath(p); ctx.setStrokeColor(c); ctx.setLineWidth(w); ctx.strokePath() }
func circle(_ c: CGPoint, _ r: Double) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }
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
    if a >= 0.999 { draw(); return }
    ctx.saveGState(); ctx.setAlpha(a); ctx.beginTransparencyLayer(auxiliaryInfo: nil); draw(); ctx.endTransparencyLayer(); ctx.restoreGState()
}
func scaled(_ s: Double, _ p: CGPoint, _ draw: () -> Void) {
    ctx.saveGState(); ctx.translateBy(x: p.x, y: p.y); ctx.scaleBy(x: s, y: s); ctx.translateBy(x: -p.x, y: -p.y); draw(); ctx.restoreGState()
}
func clipped(_ p: CGPath, _ draw: () -> Void) { ctx.saveGState(); ctx.addPath(p); ctx.clip(); draw(); ctx.restoreGState() }
func icon(_ r: CGRect) {
    ctx.saveGState(); ctx.addPath(rr(r, r.width * 0.23)); ctx.clip()
    ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
    let k = 1.22
    ctx.draw(iconImage, in: CGRect(x: -r.width * (k - 1) / 2, y: -r.height * (k - 1) / 2, width: r.width * k, height: r.height * k))
    ctx.restoreGState()
}
func font(_ s: Double, _ w: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: s, weight: w) }
@discardableResult
func text(_ s: String, _ size: Double, _ weight: NSFont.Weight = .regular, _ color: CGColor = ink, x: Double, y: Double,
          align: NSTextAlignment = .left, kern: Double = 0, maxW: Double = 4000) -> CGSize {
    let a = NSAttributedString(string: s, attributes: [.font: font(size, weight), .foregroundColor: NSColor(cgColor: color)!, .kern: kern])
    var sz = a.size()
    let w = min(sz.width, maxW)
    let ox = align == .center ? x - w / 2 : align == .right ? x - w : x
    a.draw(with: CGRect(x: ox, y: y, width: w + 1, height: sz.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    sz.width = w
    return sz
}
func textW(_ s: String, _ size: Double, _ weight: NSFont.Weight) -> Double { NSAttributedString(string: s, attributes: [.font: font(size, weight)]).size().width }
func gradText(_ s: String, _ size: Double, _ weight: NSFont.Weight, x: Double, y: Double) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font(size, weight), .kern: -size * 0.02]))
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.saveGState()
    ctx.translateBy(x: x - w / 2, y: y + font(size, weight).ascender); ctx.scaleBy(x: 1, y: -1)
    ctx.textMatrix = .identity; ctx.setTextDrawingMode(.clip); ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.drawLinearGradient(gradient(accent), start: .zero, end: CGPoint(x: w, y: 0), options: [])
    ctx.restoreGState()
}
func symbol(_ name: String, _ size: Double, _ color: CGColor, _ c: CGPoint, weight: NSFont.Weight = .semibold) {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight).applying(.init(paletteColors: [NSColor(cgColor: color)!]))) else { return }
    var r = CGRect(origin: .zero, size: img.size)
    guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return }
    let w = Double(img.size.width), h = Double(img.size.height)
    ctx.saveGState(); ctx.translateBy(x: c.x - w / 2, y: c.y + h / 2); ctx.scaleBy(x: 1, y: -1); ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); ctx.restoreGState()
}
func roundButton(_ c: CGPoint, _ r: Double, _ col: CGColor, _ sym: String) {
    fill(circle(c, r), col); symbol(sym, r * 0.78, white, c)
}
/// A generic app icon: coloured squircle with a white glyph.
func appIcon(_ r: CGRect, _ color: UInt32, _ sym: String) {
    fillGradient(rr(r, r.width * 0.24), [rgb(color), rgb(color, 0.82)], CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY))
    symbol(sym, r.width * 0.46, white, CGPoint(x: r.midX, y: r.midY))
}

// MARK: - the Mac (logical screen 1440x900)

let SW = 1440.0, SH = 900.0, menuH = 30.0
let notch = CGRect(x: SW / 2 - 92, y: 0, width: 184, height: 32)
let notes = CGRect(x: 90, y: 92, width: 780, height: 520)
let safari = CGRect(x: 210, y: 120, width: 820, height: 560)
let finder = CGRect(x: 150, y: 150, width: 700, height: 440)
let phoneWin = CGRect(x: SW - 330, y: 120, width: 260, height: 552)

func wallpaper() {
    // soft macOS-style abstract wallpaper
    fillGradient(CGPath(rect: CGRect(x: 0, y: 0, width: SW, height: SH), transform: nil), [rgb(0xC9D6FF), rgb(0xE2C9F5), rgb(0xFFD9C2)], .zero, CGPoint(x: SW, y: SH))
    let waves: [(Double, Double, UInt32, UInt32, Double)] = [(520, 120, 0x7A8CFF, 0xB59CFF, 0.55), (650, 160, 0x9C7BFF, 0xFF9FC8, 0.5), (780, 140, 0x5B7CFF, 0x7FD3FF, 0.55)]
    for (y0, amp, c1, c2, a) in waves {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: y0))
        p.addCurve(to: CGPoint(x: SW, y: y0 - amp * 0.4), control1: CGPoint(x: SW * 0.35, y: y0 - amp), control2: CGPoint(x: SW * 0.65, y: y0 + amp))
        p.addLine(to: CGPoint(x: SW, y: SH)); p.addLine(to: CGPoint(x: 0, y: SH)); p.closeSubpath()
        fillGradient(p, [rgb(c1, a), rgb(c2, a)], CGPoint(x: 0, y: y0), CGPoint(x: SW, y: SH))
    }
}

func menuBar(appName: String) {
    fillR(CGRect(x: 0, y: 0, width: SW, height: menuH), rgb(0xFFFFFF, 0.45))
    symbol("apple.logo", 15, ink, CGPoint(x: 26, y: 15))
    var x = 50.0
    for (i, item) in ([appName] + ["File", "Edit", "View", "Window", "Help"]).enumerated() {
        let w = text(item, 14, i == 0 ? .bold : .regular, ink, x: x, y: 6).width
        x += w + 20
    }
    // status items, right to left
    let clock = "Fri 31 Oct  9:41"
    var rx = SW - 16 - textW(clock, 14, .regular)
    text(clock, 14, .regular, ink, x: rx, y: 6)
    for s in ["switch.2", "magnifyingglass", "wifi", "battery.75percent"] {
        rx -= 30; symbol(s, 14, ink, CGPoint(x: rx + 10, y: 15), weight: .medium)
    }
    rx -= 30; symbol("iphone.radiowaves.left.and.right", 14, ink, CGPoint(x: rx + 10, y: 15), weight: .medium) // Hop
    // the code shown in the menu bar
    let hi = window(t, 28.2, 30.6, 0.3)
    if hi > 0 {
        alpha(hi) {
            let r = CGRect(x: rx - 92, y: 4, width: 82, height: 22)
            fill(rr(r, 6), hopBlue)
            text("482 913", 13, .bold, white, x: r.midX, y: r.minY + 3, align: .center, kern: 1)
        }
    }
    // the notch
    fill(rr(CGRect(x: notch.minX, y: -16, width: notch.width, height: notch.height + 16), 14), black)
}

func trafficLights(_ r: CGRect) {
    for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() { fill(circle(CGPoint(x: r.minX + 22 + Double(i) * 20, y: r.minY + 22), 6.5), rgb(UInt32(c))) }
}

func notesWindow(pasted: Double) {
    let r = notes
    shadowed(40, 0.25, 18) { fill(rr(r, 12), white) }
    clipped(rr(r, 12)) {
        fillR(CGRect(x: r.minX, y: r.minY, width: 210, height: r.height), rgb(0xF2F1F6))
        fillR(CGRect(x: r.minX + 210, y: r.minY, width: 220, height: r.height), rgb(0xFAFAFC))
        fillR(CGRect(x: r.minX + 210, y: r.minY, width: 1, height: r.height), rgb(0xE3E3E8))
        fillR(CGRect(x: r.minX + 430, y: r.minY, width: 1, height: r.height), rgb(0xE3E3E8))
    }
    trafficLights(r)
    text("iCloud", 12, .semibold, ink2, x: r.minX + 18, y: r.minY + 56)
    for (i, f) in ["All iCloud", "Notes", "Shopping", "Ideas"].enumerated() {
        if i == 1 { fill(rr(CGRect(x: r.minX + 10, y: r.minY + 78 + Double(i) * 30, width: 190, height: 26), 6), rgb(0xFFD60A, 0.35)) }
        symbol("folder", 13, rgb(0xE0A800), CGPoint(x: r.minX + 30, y: r.minY + 91 + Double(i) * 30))
        text(f, 13, .regular, ink, x: r.minX + 46, y: r.minY + 83 + Double(i) * 30)
    }
    for (i, n) in [("Weekend plans", "Bread, dinner…"), ("Trip ideas", "Bali, Lombok"), ("Recipes", "Nasi goreng")].enumerated() {
        let y = r.minY + 60 + Double(i) * 62
        if i == 0 { fill(rr(CGRect(x: r.minX + 218, y: y - 6, width: 204, height: 56), 8), rgb(0xFFD60A, 0.3)) }
        text(n.0, 13, .semibold, ink, x: r.minX + 228, y: y)
        text(n.1, 12, .regular, ink2, x: r.minX + 228, y: y + 20)
    }
    let ex = r.minX + 460
    text("Weekend plans", 26, .bold, ink, x: ex, y: r.minY + 56)
    text("Friday, 31 October 2026", 12, .regular, ink2, x: ex, y: r.minY + 92)
    for (i, item) in ["Pick up the bread", "Call Jaime back"].enumerated() {
        stroke(circle(CGPoint(x: ex + 9, y: r.minY + 136 + Double(i) * 34), 8), rgb(0xC7C7CC), 1.5)
        text(item, 16, .regular, ink, x: ex + 28, y: r.minY + 126 + Double(i) * 34)
    }
    if pasted > 0 {
        alpha(pasted) {
            let y = r.minY + 194
            fill(rr(CGRect(x: ex - 6, y: y - 6, width: 300, height: 34), 6), rgb(0x0A84FF, 0.18 * (1 - prog(t, 26.2, 27.0))))
            stroke(circle(CGPoint(x: ex + 9, y: y + 10), 8), rgb(0xC7C7CC), 1.5)
            text("Meet at 24 Rue Oberkampf, 8pm?", 16, .regular, ink, x: ex + 28, y: y)
        }
    }
}

func safariWindow(digits: Int, verified: Double) {
    let r = safari
    shadowed(40, 0.25, 18) { fill(rr(r, 12), white) }
    clipped(rr(r, 12)) { fillR(CGRect(x: r.minX, y: r.minY, width: r.width, height: 52), rgb(0xF5F5F7)) }
    trafficLights(r)
    fill(rr(CGRect(x: r.midX - 190, y: r.minY + 12, width: 380, height: 28), 8), rgb(0xE8E8ED))
    symbol("lock.fill", 11, ink2, CGPoint(x: r.midX - 70, y: r.minY + 26))
    text("bank.example.com", 13, .regular, ink, x: r.midX - 56, y: r.minY + 18)
    let cx = r.midX
    fill(circle(CGPoint(x: cx, y: r.minY + 140), 34), rgb(0x0A84FF, 0.12))
    symbol("checkmark.shield.fill", 34, blue, CGPoint(x: cx, y: r.minY + 140))
    text("Verify it's you", 28, .bold, ink, x: cx, y: r.minY + 196, align: .center)
    text("Enter the 6-digit code we sent to your phone.", 15, .regular, ink2, x: cx, y: r.minY + 238, align: .center)
    let code = Array("482913")
    for i in 0..<6 {
        let b = CGRect(x: cx - 189 + Double(i) * 64, y: r.minY + 286, width: 54, height: 66)
        let filled = i < digits
        fill(rr(b, 10), rgb(0xF5F5F7))
        stroke(rr(b, 10), filled ? rgb(0x0A84FF) : (i == digits && t > 29.0 && digits < 6 ? rgb(0x0A84FF, 0.6) : rgb(0xD2D2D7)), filled ? 2 : 1.5)
        if filled { text(String(code[i]), 30, .semibold, ink, x: b.midX, y: b.minY + 13, align: .center) }
    }
    let btn = CGRect(x: cx - 160, y: r.minY + 392, width: 320, height: 48)
    fill(rr(btn, 12), verified > 0 ? green : rgb(0x0A84FF, digits == 6 ? 1 : 0.4))
    text(verified > 0 ? "✓  Verified" : "Continue", 17, .semibold, white, x: btn.midX, y: btn.minY + 13, align: .center)
}

func finderWindow(dragged: Bool) {
    let r = finder
    shadowed(40, 0.25, 18) { fill(rr(r, 12), white) }
    clipped(rr(r, 12)) { fillR(CGRect(x: r.minX, y: r.minY, width: 180, height: r.height), rgb(0xF2F1F6)) }
    trafficLights(r)
    text("Downloads", 15, .bold, ink, x: r.minX + 200, y: r.minY + 16)
    for (i, f) in ["Recents", "Applications", "Desktop", "Documents", "Downloads"].enumerated() {
        if i == 4 { fill(rr(CGRect(x: r.minX + 10, y: r.minY + 56 + Double(i) * 28, width: 160, height: 24), 6), rgb(0x0A84FF, 0.15)) }
        text(f, 13, .regular, ink, x: r.minX + 36, y: r.minY + 60 + Double(i) * 28)
        symbol(["clock", "square.grid.2x2", "menubar.dock.rectangle", "doc", "arrow.down.circle"][i], 12, blue, CGPoint(x: r.minX + 22, y: r.minY + 68 + Double(i) * 28))
    }
    let files: [(String, UInt32, String)] = [("Boarding pass.pdf", 0xFF453A, "PDF"), ("Photos.zip", 0x8E8E93, "ZIP"), ("Invoice.pdf", 0xFF453A, "PDF"), ("Slides.key", 0x0A84FF, "KEY")]
    for (i, f) in files.enumerated() where !(i == 0 && dragged) {
        let x = r.minX + 220 + Double(i % 3) * 150, y = r.minY + 70 + Double(i / 3) * 160
        docIcon(CGPoint(x: x + 50, y: y + 50), f.1, f.2)
        text(f.0, 12, .regular, ink, x: x + 50, y: y + 108, align: .center)
    }
}

func docIcon(_ c: CGPoint, _ color: UInt32, _ label: String, scale: Double = 1) {
    let r = CGRect(x: c.x - 34 * scale, y: c.y - 44 * scale, width: 68 * scale, height: 88 * scale)
    shadowed(8, 0.2, 3) { fill(rr(r, 8 * scale), white) }
    stroke(rr(r, 8 * scale), rgb(0xD2D2D7), 1)
    fill(rr(CGRect(x: r.minX + 8 * scale, y: r.maxY - 30 * scale, width: r.width - 16 * scale, height: 20 * scale), 4 * scale), rgb(color))
    text(label, 11 * scale, .bold, white, x: r.midX, y: r.maxY - 28 * scale, align: .center)
}

// MARK: - Hop's island (the real design: black, Hop glow, edge in Hop's colours)

enum Island { case connecting, notif(String, String), typing(String), sent, call, answered, clip, code, file }

func island(_ kind: Island, open: Double, width: Double, height: Double, green: Bool = false) {
    let w = mix(notch.width, width, open), h = mix(notch.height, height, open)
    let r = CGRect(x: SW / 2 - w / 2, y: 0, width: w, height: h)
    let rad = min(22, h / 2)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: r.minX, y: r.minY)); path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - rad, y: r.maxY), radius: rad)
    path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - rad), radius: rad)
    path.closeSubpath()
    shadowed(30, 0.35 * open, 10) { fill(path, black) }
    let edge = green ? [rgb(0x34C759), rgb(0x30D158), rgb(0x34C759)] : accent
    if open > 0.05 {
        clipped(path) { glow(CGPoint(x: r.minX + 40, y: r.minY), w * 0.7, edge[0].copy(alpha: 0.32 * open)!) }
        ctx.saveGState(); ctx.addPath(path); ctx.setLineWidth(1.6); ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(gradient(edge), start: CGPoint(x: r.minX, y: 0), end: CGPoint(x: r.maxX, y: 0), options: [])
        ctx.restoreGState()
    }
    let c = open > 0.6 ? (open - 0.6) / 0.4 : 0
    guard c > 0 else { return }
    alpha(c) {
        let cy = r.maxY - 36, x0 = r.minX + 18
        func status(_ title: String, _ sub: String? = nil, spin: Bool = false, tick: Bool = false) {
            icon(CGRect(x: x0, y: cy - 15, width: 30, height: 30))
            if let sub {
                text(title, 14, .semibold, white, x: x0 + 42, y: cy - 18)
                text(sub, 12, .regular, rgb(0xFFFFFF, 0.72), x: x0 + 42, y: cy)
            } else { text(title, 14, .semibold, white, x: x0 + 42, y: cy - 9) }
            if spin {
                ctx.saveGState(); ctx.translateBy(x: r.maxX - 28, y: cy); ctx.rotate(by: t * 7)
                let p = CGMutablePath(); p.addArc(center: .zero, radius: 8, startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
                ctx.addPath(p); ctx.setStrokeColor(white); ctx.setLineWidth(2.2); ctx.setLineCap(.round); ctx.strokePath(); ctx.restoreGState()
            }
            if tick { symbol("checkmark.circle.fill", 17, rgb(0x34C759), CGPoint(x: r.maxX - 28, y: cy)) }
        }
        switch kind {
        case .connecting: status("Connecting to Galaxy S25…", spin: true)
        case .sent: status("Reply sent", tick: true)
        case .clip: status("Copied from your phone", tick: true)
        case .code: status("Code 482 913 copied", "From your bank · paste with ⌘V")
        case .file: status("Sent to Galaxy S25", "Boarding pass.pdf", tick: true)
        case .notif(let title, let body):
            notifRow(r, cy: cy, title: title, body: body, typing: nil)
        case .typing(let s):
            notifRow(r, cy: cy, title: "Mum", body: "", typing: s)
        case .call, .answered:
            let answered: Bool = { if case .answered = kind { return true }; return false }()
            symbol("phone.fill", 18, rgb(0x34C759), CGPoint(x: x0 + 14, y: cy))
            text("Jaime", 15, .semibold, white, x: x0 + 38, y: cy - 18)
            text(answered ? "On a call on your phone" : "Incoming call · mobile", 12, .regular, rgb(0xFFFFFF, 0.72), x: x0 + 38, y: cy)
            if !answered {
                roundButton(CGPoint(x: r.maxX - 74, y: cy), 17, red, "phone.down.fill")
                roundButton(CGPoint(x: r.maxX - 32, y: cy), 17, rgb(0x34C759), "phone.fill")
            }
        }
    }
}

func notifRow(_ r: CGRect, cy: Double, title: String, body: String, typing: String?) {
    let x0 = r.minX + 18
    appIcon(CGRect(x: x0, y: cy - 22, width: 38, height: 38), 0x34C759, "message.fill")
    text("MESSAGES · NOW", 10, .semibold, rgb(0xFFFFFF, 0.5), x: x0 + 50, y: cy - 26, kern: 0.6)
    text(title, 14, .semibold, white, x: x0 + 50, y: cy - 13)
    if let s = typing {
        fill(rr(CGRect(x: x0 + 50, y: cy + 6, width: r.width - 160, height: 22), 6), rgb(0xFFFFFF, 0.13))
        let sz = text(s, 12, .regular, white, x: x0 + 58, y: cy + 9)
        if Int(t * 2.5) % 2 == 0 { fillR(CGRect(x: x0 + 59 + sz.width, y: cy + 10, width: 1.5, height: 14), white) }
    } else {
        text(body, 12, .regular, rgb(0xFFFFFF, 0.78), x: x0 + 50, y: cy + 5, maxW: r.width - 170)
    }
    roundButton(CGPoint(x: r.maxX - 58, y: cy - 2), 12, rgb(0xFFFFFF, 0.16), "arrowshape.turn.up.left.fill")
    roundButton(CGPoint(x: r.maxX - 26, y: cy - 2), 12, rgb(0xFFFFFF, 0.16), "xmark")
}

func drawIsland() {
    let typedReply = String("On my way! 🥖".prefix(Int(13 * prog(t, 12.1, 13.3))))
    let states: [(Double, Double, Island, Double, Double, Bool)] = [
        (6.0, 7.4, .connecting, 300, 64, false),
        (10.2, 11.8, .notif("Mum", "Dinner at 7? Bring the bread 🍞"), 420, 82, false),
        (11.8, 13.6, .typing(typedReply), 420, 82, false),
        (13.6, 14.3, .sent, 230, 64, true),
        (14.6, 15.4, .notif("Mum", "Great, see you soon 😊"), 420, 82, false),
        (18.9, 20.3, .call, 360, 72, true),
        (20.3, 21.4, .answered, 360, 72, true),
        (24.2, 25.2, .clip, 300, 64, true),
        (28.2, 29.6, .code, 330, 72, false),
        (33.5, 34.5, .file, 300, 72, true),
    ]
    for (i, s) in states.enumerated() {
        let (a, b, kind, w, h, g) = s
        guard t >= a - 0.01 && t <= b + 0.45 else { continue }
        let chainedIn = i > 0 && abs(states[i - 1].1 - a) < 0.01
        let chainedOut = i + 1 < states.count && abs(states[i + 1].0 - b) < 0.01
        if t > b && chainedOut { continue }
        // a chained state that changes size morphs smoothly from the previous one
        var width = w, height = h
        if chainedIn {
            let m = smoother(prog(t, a, a + 0.35))
            width = mix(states[i - 1].3, w, m); height = mix(states[i - 1].4, h, m)
        }
        let o = (chainedIn ? 1 : back(prog(t, a, a + 0.45))) * (1 - (chainedOut ? 0 : easeIn(prog(t, b, b + 0.3))))
        island(kind, open: clamp(o, 0, 1.15), width: width, height: height, green: g)
        return
    }
}

// MARK: - Android screens

func statusBar(_ r: CGRect, dark: Bool = false, scale k: Double) {
    let c = dark ? ink : white
    text("9:41", 13 * k, .semibold, c, x: r.minX + 22 * k, y: r.minY + 12 * k)
    symbol("wifi", 11 * k, c, CGPoint(x: r.maxX - 66 * k, y: r.minY + 21 * k), weight: .medium)
    symbol("cellularbars", 11 * k, c, CGPoint(x: r.maxX - 46 * k, y: r.minY + 21 * k), weight: .medium)
    symbol("battery.75percent", 13 * k, c, CGPoint(x: r.maxX - 22 * k, y: r.minY + 21 * k), weight: .medium)
}

/// The Android home screen at any size (k = scale relative to a 260-wide screen).
func androidHome(_ r: CGRect, radius: Double) {
    let k = r.width / 260
    clipped(rr(r, radius)) {
        fillGradient(CGPath(rect: r, transform: nil), [rgb(0x2B3A8F), rgb(0x6A4BC9), rgb(0xE07AA6)], CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY))
        glow(CGPoint(x: r.maxX, y: r.minY + r.height * 0.3), r.width * 0.9, rgb(0x00C6FF, 0.35))
        statusBar(r, scale: k)
        text("9:41", 58 * k, .light, white, x: r.midX, y: r.minY + 60 * k, align: .center)
        text("Friday, 31 October", 13 * k, .medium, rgb(0xFFFFFF, 0.9), x: r.midX, y: r.minY + 134 * k, align: .center)
        let apps: [(UInt32, String)] = [(0x34C759, "phone.fill"), (0x0A84FF, "message.fill"), (0xFF9500, "camera.fill"), (0xAF52DE, "photo.on.rectangle"),
                                        (0xFF2D55, "music.note"), (0x5AC8FA, "map.fill"), (0x30B0C7, "envelope.fill"), (0x8E8E93, "gearshape.fill")]
        let gap = 14 * k, size = (r.width - gap * 5) / 4
        for (i, a) in apps.enumerated() {
            let x = r.minX + gap + Double(i % 4) * (size + gap), y = r.maxY - 168 * k + Double(i / 4) * (size + gap)
            appIcon(CGRect(x: x, y: y, width: size, height: size), a.0, a.1)
        }
        fill(rr(CGRect(x: r.minX + 16 * k, y: r.maxY - 46 * k, width: r.width - 32 * k, height: 32 * k), 16 * k), rgb(0xFFFFFF, 0.85))
        symbol("magnifyingglass", 12 * k, ink2, CGPoint(x: r.minX + 34 * k, y: r.maxY - 30 * k))
        text("Search", 12 * k, .regular, ink2, x: r.minX + 46 * k, y: r.maxY - 37 * k)
    }
}

/// The Messages chat with Mum, as opened from the notification.
func androidChat(_ r: CGRect, radius: Double) {
    let k = r.width / 260
    clipped(rr(r, radius)) {
        fillR(r, rgb(0xF4F5F9))
        fillR(CGRect(x: r.minX, y: r.minY, width: r.width, height: 92 * k), white)
        statusBar(r, dark: true, scale: k)
        symbol("chevron.left", 14 * k, ink, CGPoint(x: r.minX + 20 * k, y: r.minY + 64 * k))
        fill(circle(CGPoint(x: r.minX + 52 * k, y: r.minY + 64 * k), 15 * k), rgb(0xFF9F0A))
        text("M", 14 * k, .bold, white, x: r.minX + 52 * k, y: r.minY + 55 * k, align: .center)
        text("Mum", 15 * k, .semibold, ink, x: r.minX + 76 * k, y: r.minY + 55 * k)
        func bubble(_ s: String, mine: Bool, y: Double) {
            let w = min(textW(s, 13 * k, .regular) + 26 * k, r.width * 0.75)
            let b = CGRect(x: mine ? r.maxX - 14 * k - w : r.minX + 14 * k, y: r.minY + y * k, width: w, height: 34 * k)
            fill(rr(b, 17 * k), mine ? rgb(0x0A84FF) : white)
            text(s, 13 * k, .regular, mine ? white : ink, x: b.minX + 13 * k, y: b.minY + 8 * k, maxW: w - 20 * k)
        }
        bubble("Dinner at 7? Bring the bread 🍞", mine: false, y: 120)
        bubble("On my way! 🥖", mine: true, y: 166)
        bubble("Great, see you soon 😊", mine: false, y: 212)
        fill(rr(CGRect(x: r.minX + 12 * k, y: r.maxY - 52 * k, width: r.width - 24 * k, height: 36 * k), 18 * k), white)
        text("Message", 13 * k, .regular, ink2, x: r.minX + 28 * k, y: r.maxY - 43 * k)
    }
}

func androidCall(_ r: CGRect, radius: Double) {
    let k = r.width / 260
    clipped(rr(r, radius)) {
        fillGradient(CGPath(rect: r, transform: nil), [rgb(0x0F3D2E), rgb(0x0B1F18)], CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.maxY))
        statusBar(r, scale: k)
        fill(circle(CGPoint(x: r.midX, y: r.minY + 140 * k), 40 * k), rgb(0xFFFFFF, 0.15))
        text("J", 34 * k, .semibold, white, x: r.midX, y: r.minY + 119 * k, align: .center)
        text("Jaime", 24 * k, .semibold, white, x: r.midX, y: r.minY + 196 * k, align: .center)
        text("Incoming call", 13 * k, .regular, rgb(0xFFFFFF, 0.7), x: r.midX, y: r.minY + 230 * k, align: .center)
        roundButton(CGPoint(x: r.midX - 62 * k, y: r.maxY - 70 * k), 26 * k, red, "phone.down.fill")
        roundButton(CGPoint(x: r.midX + 62 * k, y: r.maxY - 70 * k), 26 * k, rgb(0x34C759), "phone.fill")
    }
}

// MARK: - real Android footage (recorded on an emulator, see footage/)

var footageGens: [String: AVAssetImageGenerator] = [:]
var footageCache: [String: CGImage] = [:]
/// A frame of footage/<clip>.mp4 at `time` seconds, held on its last frame.
func footageFrame(_ clip: String, _ time: Double) -> CGImage? {
    let gen = footageGens[clip] ?? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: "footage/\(clip).mp4")))
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        footageGens[clip] = g
        return g
    }()
    let f = max(0, Int(time * 30))
    let key = "\(clip)#\(f)"
    if let img = footageCache[key] { return img }
    var img: CGImage?
    for back in 0..<120 where img == nil {   // past the end: walk back to the last frame
        img = try? gen.copyCGImage(at: CMTime(value: CMTimeValue(max(0, f - back)), timescale: 30), actualTime: nil)
    }
    if footageCache.count > 8 { footageCache.removeAll() }
    footageCache[key] = img
    return img
}

/// Draws footage filling a phone screen rect.
func footage(_ clip: String, _ time: Double, _ r: CGRect, radius: Double) {
    guard let img = footageFrame(clip, time) else { return }
    clipped(rr(r, radius)) {
        let ar = Double(img.width) / Double(img.height)
        let w = max(r.width, r.height * ar), h = w / ar
        let d = CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
        ctx.saveGState()
        ctx.translateBy(x: d.minX, y: d.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: d.width, height: d.height))
        ctx.restoreGState()
    }
}

/// The phone's screen, shown on the phone and mirrored in Hop's window.
func phoneScreen(_ r: CGRect, radius: Double) {
    footage("chat", 0.3, r, radius: radius)
    // a notification opened from the Mac: the Mum chat
    let chat = easeInOut(prog(t, 15.7, 16.1))
    if chat > 0 { alpha(chat) { footage("chat", min(7.0, 3.0 + max(0, t - 15.9) * 0.6), r, radius: radius) } }
    // the call rings, then is answered from the Mac's island
    alpha(window(t, 18.7, 20.3, 0.2)) { footage("call", 5.3 + (t - 18.7), r, radius: radius) }
    // long-press Jaime's message to copy the address
    alpha(window(t, 22.9, 24.1, 0.25)) { footage("copy", 1.5 + (t - 22.9), r, radius: radius) }
    // the bank's code arrives
    alpha(window(t, 27.9, 29.8, 0.3)) { footage("code", 1.0 + (t - 27.9), r, radius: radius) }
}

/// The real phone, beside the Mac.
func phoneMockup(_ c: CGPoint, scale k: Double, screen: (CGRect, Double) -> Void) {
    let body = CGRect(x: c.x - 135 * k, y: c.y - 285 * k, width: 270 * k, height: 570 * k)
    shadowed(50, 0.3, 26) { fill(rr(body, 42 * k), rgb(0x2B2D33)) }
    fillGradient(rr(body, 42 * k), [rgb(0x9A9EA8), rgb(0x55585F), rgb(0x8C9099)], CGPoint(x: body.minX, y: body.minY), CGPoint(x: body.maxX, y: body.maxY))
    let glass = body.insetBy(dx: 5 * k, dy: 5 * k)
    fill(rr(glass, 38 * k), black)
    let s = glass.insetBy(dx: 5 * k, dy: 5 * k)
    screen(s, 33 * k)
    fill(circle(CGPoint(x: s.midX, y: s.minY + 16 * k), 5 * k), black)
    // side buttons
    fill(rr(CGRect(x: body.maxX - 1, y: body.minY + 120 * k, width: 4 * k, height: 70 * k), 2), rgb(0x6D717B))
    fill(rr(CGRect(x: body.maxX - 1, y: body.minY + 210 * k, width: 4 * k, height: 40 * k), 2), rgb(0x6D717B))
}

// MARK: - the screen content at time t

func cursor(_ p: CGPoint, click: Double = 0) {
    if click > 0 && click < 1 {
        let r = 8 + 22 * click
        fill(circle(p, r), rgb(0x0A84FF, 0.25 * (1 - click)))
        stroke(circle(p, r), rgb(0x0A84FF, 0.6 * (1 - click)), 2)
    }
    let s = 1.0
    let pts: [(Double, Double)] = [(0, 0), (0, 24), (6, 18.5), (10.5, 28.5), (14.5, 26.8), (10.2, 17.2), (17.5, 16.8)]
    let path = CGMutablePath()
    path.move(to: p)
    for q in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x + q.0 * s, y: p.y + q.1 * s)) }
    path.closeSubpath()
    shadowed(6, 0.35, 2) { fill(path, black) }
    ctx.addPath(path); ctx.setStrokeColor(white); ctx.setLineWidth(1.6); ctx.setLineJoin(.round); ctx.strokePath()
}

/// Cursor path through the film: (time, point, clickAt?)
let cursorKeys: [(Double, CGPoint)] = [
    (3.0, CGPoint(x: 980, y: 700)), (10.6, CGPoint(x: 980, y: 700)),
    (11.3, CGPoint(x: SW / 2 + 210 - 58, y: 82 - 38)),                 // Reply
    (14.6, CGPoint(x: SW / 2 + 210 - 58, y: 82 - 38)),
    (15.1, CGPoint(x: SW / 2 - 40, y: 54)),                            // click the notification
    (18.9, CGPoint(x: SW / 2 - 40, y: 70)),
    (19.6, CGPoint(x: SW / 2 + 180 - 32, y: 72 - 36)),                 // Answer
    (22.0, CGPoint(x: SW / 2 + 180 - 32, y: 72 - 36)),
    (22.8, CGPoint(x: 620, y: 300)), (24.6, CGPoint(x: 620, y: 300)),
    (25.0, CGPoint(x: 560, y: 300)),                                   // into Notes
    (27.6, CGPoint(x: 560, y: 300)),
    (28.6, CGPoint(x: safari.midX - 166, y: safari.minY + 320)),       // first code box
    (31.8, CGPoint(x: safari.midX - 166, y: safari.minY + 320)),
    (32.3, CGPoint(x: finder.minX + 270, y: finder.minY + 120)),       // grab the PDF
    (33.3, CGPoint(x: phoneWin.midX - 10, y: phoneWin.midY)),          // drop on the phone window
    (36.0, CGPoint(x: phoneWin.midX - 10, y: phoneWin.midY)),
]
func cursorPos(_ t: Double) -> CGPoint {
    for i in 0..<(cursorKeys.count - 1) where t <= cursorKeys[i + 1].0 {
        return lerpP(cursorKeys[i].1, cursorKeys[i + 1].1, smoother(prog(t, cursorKeys[i].0, cursorKeys[i + 1].0)))
    }
    return cursorKeys.last!.1
}
let clicks: [Double] = [11.45, 15.25, 19.75, 28.75, 32.4]

func screenContent() {
    wallpaper()
    // which app is in front
    let showNotes = t < 27.4, showSafari = t >= 27.2 && t < 31.9, showFinder = t >= 31.7 && t < 35.6
    if showNotes { alpha(1 - easeIn(prog(t, 27.2, 27.5))) { notesWindow(pasted: easeOut(prog(t, 25.3, 25.6))) } }
    if showSafari {
        let digits = Int(6 * prog(t, 29.5, 30.1))
        alpha(easeOut(prog(t, 27.2, 27.6)) * (1 - easeIn(prog(t, 31.7, 32.0)))) { safariWindow(digits: digits, verified: prog(t, 30.5, 30.6)) }
    }
    if showFinder { alpha(easeOut(prog(t, 31.7, 32.1)) * (1 - easeIn(prog(t, 35.4, 35.7)))) { finderWindow(dragged: t > 32.4) } }

    // dock mode: a big Hop window with the phone's desktop
    let dock = easeInOut(prog(t, 36.0, 36.7)) * (1 - easeInOut(prog(t, 40.0, 40.4)))
    if dock > 0 {
        alpha(dock) {
            let r = CGRect(x: 60, y: 60, width: SW - 120, height: SH - 100)
            scaled(mix(0.9, 1, easeOut(prog(t, 36.0, 36.7))), CGPoint(x: r.midX, y: r.midY)) {
                shadowed(50, 0.35, 20) { fill(rr(r, 12), rgb(0x16182A)) }
                clipped(rr(r, 12)) {
                    fillGradient(CGPath(rect: r, transform: nil), [rgb(0x2B3A8F), rgb(0x6A4BC9), rgb(0xE07AA6)], CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY))
                    fillR(CGRect(x: r.minX, y: r.minY, width: r.width, height: 30), rgb(0xECECEF))
                }
                trafficLights(CGRect(x: r.minX - 4, y: r.minY - 7, width: 0, height: 0))
                text("Galaxy S25 · Dock", 13, .semibold, ink, x: r.midX, y: r.minY + 7, align: .center)
                let k = easeOut(prog(t, 36.6, 37.3))
                for (i, wr) in [CGRect(x: r.minX + 70, y: r.minY + 80, width: 560, height: 520), CGRect(x: r.minX + 560, y: r.minY + 140, width: 620, height: 520)].enumerated() {
                    alpha(k) {
                        let q = wr.offsetBy(dx: 0, dy: (1 - k) * 40 * Double(i + 1))
                        shadowed(30, 0.3, 12) { fill(rr(q, 14), white) }
                        fillR(CGRect(x: q.minX, y: q.minY + 14, width: q.width, height: 30), rgb(0xF4F5F9))
                        text(i == 0 ? "Messages" : "Browser", 14, .semibold, ink, x: q.minX + 18, y: q.minY + 14)
                        if i == 0 {
                            for (j, s) in ["Mum: Great, see you soon 😊", "Jaime: Missed call", "Dimas: Lunch tomorrow?", "Bank: Your code is 482913"].enumerated() {
                                let y = q.minY + 70 + Double(j) * 70
                                fill(circle(CGPoint(x: q.minX + 40, y: y + 22), 20), rgb([0xFF9F0A, 0x34C759, 0x5AC8FA, 0xAF52DE][j]))
                                text(s, 15, .regular, ink, x: q.minX + 72, y: y + 12)
                            }
                        } else {
                            fill(rr(CGRect(x: q.minX + 20, y: q.minY + 64, width: q.width - 40, height: 30), 15), rgb(0xF0F1F5))
                            fill(rr(CGRect(x: q.minX + 20, y: q.minY + 116, width: q.width - 40, height: 180), 12), rgb(0xE8EBFF))
                            for j in 0..<4 { fill(rr(CGRect(x: q.minX + 20, y: q.minY + 316 + Double(j) * 40, width: q.width - 40 - Double(j % 2) * 140, height: 22), 6), rgb(0xF0F1F5)) }
                        }
                    }
                }
                let tb = CGRect(x: r.minX, y: r.maxY - 56, width: r.width, height: 56)
                clipped(rr(r, 12)) { fillR(tb, rgb(0x000000, 0.35)) }
                let apps: [(UInt32, String)] = [(0x34C759, "phone.fill"), (0x0A84FF, "message.fill"), (0xFF9500, "camera.fill"), (0xAF52DE, "photo.on.rectangle"), (0x30B0C7, "envelope.fill")]
                for (i, a) in apps.enumerated() { appIcon(CGRect(x: r.midX - 130 + Double(i) * 54, y: tb.minY + 10, width: 36, height: 36), a.0, a.1) }
            }
        }
    }

    // Hop's phone window: springs out of the notch, shows the chat after a click, goes for dock mode
    let winIn = back(prog(t, 7.3, 7.95)) * (1 - easeIn(prog(t, 35.7, 36.1)))
    if winIn > 0.01 {
        let anchor = CGPoint(x: SW / 2, y: 10)
        ctx.saveGState()
        ctx.translateBy(x: mix(anchor.x, phoneWin.midX, winIn), y: mix(anchor.y, phoneWin.midY, winIn))
        ctx.scaleBy(x: max(0.05, winIn), y: max(0.05, winIn))
        ctx.translateBy(x: -phoneWin.midX, y: -phoneWin.midY)
        alpha(clamp(winIn * 1.4)) {
            shadowed(36, 0.35, 16) { fill(rr(phoneWin, 38), black) }
            stroke(rr(phoneWin, 38), rgb(0xFFFFFF, 0.14), 1)
            let s = phoneWin.insetBy(dx: 8, dy: 8)
            phoneScreen(s, radius: 31)
            // drop highlight
            let drop = window(t, 33.0, 33.4, 0.15)
            if drop > 0 { stroke(rr(phoneWin.insetBy(dx: -2, dy: -2), 40), rgb(0x0A84FF, drop), 4) }
            // the hover toolbar
            let tb = CGRect(x: phoneWin.midX - 66, y: phoneWin.minY - 40, width: 132, height: 28)
            fill(rr(tb, 14), rgb(0x2A2C36, 0.92))
            for (i, s) in ["xmark", "chevron.backward", "circle", "square.on.square"].enumerated() {
                symbol(s, 11, rgb(0xFFFFFF, 0.85), CGPoint(x: tb.minX + 21 + Double(i) * 30, y: tb.midY))
            }
        }
        ctx.restoreGState()
    }

    // the PDF being dragged onto the phone
    if t > 32.4 && t < 33.5 {
        let p = cursorPos(t)
        let drop = easeIn(prog(t, 33.3, 33.5))
        alpha(1 - drop) { docIcon(CGPoint(x: p.x + 20, y: p.y + 30), 0xFF453A, "PDF", scale: 1 - 0.5 * drop) }
    }

    menuBar(appName: t < 27.3 ? "Notes" : t < 31.8 ? "Safari" : t < 35.7 ? "Finder" : "Hop")
    drawIsland()
    if t > 3.4 && t < 36.2 { cursor(cursorPos(t), click: clicks.map { prog(t, $0, $0 + 0.35) }.first { $0 > 0 && $0 < 1 } ?? 0) }
}

// MARK: - camera (zoom into the recording)

/// (time, zoom, focus x, focus y) in screen coordinates.
let zoomKeys: [(Double, Double, Double, Double)] = [
    (0, 1, 720, 450), (5.7, 1, 720, 450), (6.3, 2.0, 720, 120), (7.1, 2.0, 720, 120), (7.8, 1, 720, 450),
    (9.8, 1, 720, 450), (10.3, 2.1, 720, 110), (14.0, 2.1, 720, 110), (15.4, 1.9, 760, 140), (15.9, 1.35, 1060, 400),
    (18.4, 1.35, 1060, 400), (18.9, 2.1, 720, 110), (21.6, 2.1, 720, 110), (22.4, 1, 720, 450),
    (24.6, 1, 720, 450), (25.1, 1.7, 560, 300), (27.0, 1.7, 560, 300), (27.6, 1.15, 640, 380),
    (28.0, 1.15, 640, 380), (28.5, 1.7, 720, 200), (29.4, 1.7, 720, 200), (29.8, 1.6, 620, 380), (31.4, 1.6, 620, 380), (31.9, 1, 720, 450),
    (35.8, 1, 720, 450), (40.4, 1, 720, 450),
]
func zoomAt(_ t: Double) -> (Double, Double, Double) {
    for i in 0..<(zoomKeys.count - 1) where t <= zoomKeys[i + 1].0 {
        let a = zoomKeys[i], b = zoomKeys[i + 1], p = smoother(prog(t, a.0, b.0))
        return (mix(a.1, b.1, p), mix(a.2, b.2, p), mix(a.3, b.3, p))
    }
    let l = zoomKeys.last!; return (l.1, l.2, l.3)
}

// MARK: - the composition

func background() {
    fillGradient(CGPath(rect: CGRect(x: 0, y: 0, width: W, height: H), transform: nil), [rgb(0xEEF0FF), rgb(0xF6EEFF), rgb(0xFFF1EA)], .zero, CGPoint(x: W, y: H))
    glow(CGPoint(x: 300 + 80 * sin(t * 0.3), y: 200), 700, rgb(0x8A5CFF, 0.16))
    glow(CGPoint(x: 1650, y: 900 + 60 * cos(t * 0.25)), 800, rgb(0x00C6FF, 0.14))
}

func headline(_ a: Double, _ b: Double, _ l1: String, _ l2: String) {
    let v = window(t, a, b, 0.5)
    guard v > 0 else { return }
    alpha(v) {
        let y = 40 + (1 - v) * 16
        let w1 = textW(l1, 40, .semibold), w2 = textW(" " + l2, 40, .semibold)
        let x0 = frameRect().midX - (w1 + w2) / 2
        text(l1, 40, .semibold, ink, x: x0, y: y, kern: -0.6)
        text(" " + l2, 40, .semibold, ink2, x: x0 + w1, y: y, kern: -0.6)
    }
}

func phoneShift() -> Double { easeInOut(prog(t, 3.9, 4.6)) * (1 - easeInOut(prog(t, 35.6, 36.2))) }
func frameRect() -> CGRect {
    let w = 1440.0 * 0.98, h = 900.0 * 0.98
    let x = mix((W - w) / 2, 64, phoneShift())
    return CGRect(x: x, y: 118, width: w, height: h)
}

func keycaps(_ keys: [String], at c: CGPoint, _ v: Double) {
    guard v > 0 else { return }
    alpha(v) {
        scaled(mix(0.85, 1, back(v)), c) {
            let total = Double(keys.count) * 64 + Double(keys.count - 1) * 10
            for (i, k) in keys.enumerated() {
                let r = CGRect(x: c.x - total / 2 + Double(i) * 74, y: c.y - 32, width: 64, height: 64)
                shadowed(16, 0.25, 6) { fill(rr(r, 14), white) }
                stroke(rr(r, 14), rgb(0xD2D2D7), 1)
                text(k, 30, .medium, ink, x: r.midX, y: r.minY + 13, align: .center)
            }
        }
    }
}

/// The whole film: a keynote-style cold open, the demo, the encryption story, then the recap and outro.
func frame(_ T: Double) {
    let local = T < 44.4 ? T - 4 : T < 54.4 ? 40.45 : T - 14
    mainFrame(max(0, local))
    let co = 1 - easeInOut(prog(T, 3.6, 4.4))
    if co > 0 { alpha(co) { coldOpen(T) } }
    let enc = window(T, 44.0, 54.0, 0.6)
    if enc > 0 { alpha(enc) { encryption(T - 44.4) } }
}

// MARK: - keynote-style sequences (black)

func keynoteBackground(_ glowAt: CGPoint) {
    fillR(CGRect(x: 0, y: 0, width: W, height: H), rgb(0x000000))
    glow(glowAt, 900, rgb(0x2A3BFF, 0.18))
}

func coldOpen(_ T: Double) {
    keynoteBackground(CGPoint(x: W / 2, y: H * 0.55))
    func word(_ s: String, _ a: Double, _ y: Double, grad: Bool = false) {
        let v = easeOut(prog(T, a, a + 0.7)) * (1 - easeIn(prog(T, 3.3, 3.8)))
        guard v > 0 else { return }
        alpha(v) {
            let yy = y + (1 - v) * 18
            if grad { gradText(s, 110, .bold, x: W / 2, y: yy) } else { text(s, 110, .bold, white, x: W / 2, y: yy, align: .center, kern: -3) }
        }
    }
    word("Your Mac.", 0.3, 290)
    word("Your Android.", 1.1, 430)
    word("Finally, together.", 2.0, 570, grad: true)
}

/// Line-art phone and Mac, glowing, for the security story.
func lineDevices(_ e: Double, phone: CGRect, mac: CGRect, phoneScreen: () -> Void, macScreen: () -> Void) {
    let line = rgb(0xFFFFFF, 0.85)
    shadowed(30, 0.0, 0) {}
    // phone
    fill(rr(phone, 38), rgb(0x0B0D14))
    stroke(rr(phone, 38), line, 2)
    clipped(rr(phone.insetBy(dx: 10, dy: 10), 30)) { phoneScreen() }
    // mac
    let screen = CGRect(x: mac.minX, y: mac.minY, width: mac.width, height: mac.height * 0.82)
    fill(rr(screen, 18), rgb(0x0B0D14))
    stroke(rr(screen, 18), line, 2)
    clipped(rr(screen.insetBy(dx: 12, dy: 12), 10)) { macScreen() }
    let base = CGMutablePath()
    base.move(to: CGPoint(x: mac.minX - 50, y: mac.maxY)); base.addLine(to: CGPoint(x: mac.maxX + 50, y: mac.maxY))
    base.addLine(to: CGPoint(x: mac.maxX + 30, y: mac.maxY - mac.height * 0.1)); base.addLine(to: CGPoint(x: mac.minX - 30, y: mac.maxY - mac.height * 0.1)); base.closeSubpath()
    fill(base, rgb(0x0B0D14)); stroke(base, line, 2)
    fill(rr(CGRect(x: screen.midX - 50, y: screen.minY, width: 100, height: 16), 8), rgb(0x000000))
}

/// Deterministic scrambled text that keeps changing, like ciphertext streaming past.
func cipher(_ n: Int, _ seed: Int) -> String {
    let chars = Array("0123456789abcdef")
    var x = UInt64(seed &* 2654435761 &+ 1)
    return String((0..<n).map { _ in x = x &* 6364136223846793005 &+ 1442695040888963407; return chars[Int((x >> 33) % 16)] })
}

func encryption(_ e: Double) {
    keynoteBackground(CGPoint(x: W / 2, y: 620))
    let phone = CGRect(x: 300, y: 330, width: 210, height: 430)
    let mac = CGRect(x: 1140, y: 330, width: 520, height: 400)
    let captionY = 120.0
    func caption(_ a: Double, _ b: Double, _ l1: String, _ l2: String) {
        let v = window(e, a, b, 0.5)
        guard v > 0 else { return }
        alpha(v) {
            text(l1, 56, .bold, white, x: W / 2, y: captionY + (1 - v) * 14, align: .center, kern: -1.4)
            gradText(l2, 30, .semibold, x: W / 2, y: captionY + 80 + (1 - v) * 14)
        }
    }
    caption(0.2, 2.6, "Pair once.", "One key. Only your two devices hold it.")
    caption(3.0, 6.4, "Encrypted before it leaves your phone.", "AES-256-GCM · a fresh key for every connection")
    caption(6.8, 9.6, "Never through the cloud.", "Phone to Mac, directly. No servers. No account.")

    let appear = easeOut(prog(e, 0.0, 0.6))
    alpha(appear) {
        lineDevices(e, phone: phone, mac: mac, phoneScreen: {
            let s = phone.insetBy(dx: 10, dy: 10)
            // scanning frame
            let scan = window(e, 0.5, 1.6, 0.2)
            alpha(scan) {
                let f = CGRect(x: s.midX - 60, y: s.midY - 60, width: 120, height: 120)
                for (cx, cy, dx, dy) in [(f.minX, f.minY, 1.0, 1.0), (f.maxX, f.minY, -1.0, 1.0), (f.minX, f.maxY, 1.0, -1.0), (f.maxX, f.maxY, -1.0, -1.0)] {
                    let p = CGMutablePath(); p.move(to: CGPoint(x: cx, y: cy + dy * 24)); p.addLine(to: CGPoint(x: cx, y: cy)); p.addLine(to: CGPoint(x: cx + dx * 24, y: cy))
                    stroke(p, rgb(0x00C6FF), 3)
                }
                let ly = f.minY + f.height * (0.5 + 0.5 * sin(e * 6))
                fillR(CGRect(x: f.minX + 6, y: ly, width: f.width - 12, height: 2), rgb(0x00C6FF, 0.8))
            }
            // the message about to be sent
            let msg = window(e, 2.8, 3.4, 0.3)
            alpha(msg) {
                let b = CGRect(x: s.minX + 16, y: s.midY - 20, width: s.width - 32, height: 44)
                fill(rr(b, 22), rgb(0x0A84FF))
                text("Dinner at 7? 🍞", 17, .medium, white, x: b.midX, y: b.minY + 12, align: .center)
            }
        }, macScreen: {
            let s = CGRect(x: mac.minX + 12, y: mac.minY + 12, width: mac.width - 24, height: mac.height * 0.82 - 24)
            // QR code
            let qr = window(e, 0.3, 1.6, 0.3)
            alpha(qr) {
                let n = 21, size = 8.0, x0 = s.midX - Double(n) * size / 2, y0 = s.midY - Double(n) * size / 2
                fill(rr(CGRect(x: x0 - 14, y: y0 - 14, width: Double(n) * size + 28, height: Double(n) * size + 28), 10), white)
                var h: UInt64 = 1469598103934665603
                for i in 0..<n { for j in 0..<n {
                    h = (h ^ UInt64(i * 31 + j)) &* 1099511628211
                    let finder = (i < 7 && j < 7) || (i < 7 && j >= n - 7) || (i >= n - 7 && j < 7)
                    let on = finder ? (i % 6 == 0 || j % 6 == 0 || (i % 6 >= 2 && i % 6 <= 4 && j % 6 >= 2 && j % 6 <= 4)) : (h >> 40) & 1 == 1
                    if on { fillR(CGRect(x: x0 + Double(j) * size, y: y0 + Double(i) * size, width: size, height: size), black) }
                } }
            }
            // the decoded message arrives in the island
            let got = easeOut(prog(e, 5.3, 5.8)) * (1 - easeIn(prog(e, 9.4, 9.8)))
            alpha(got) {
                let isl = CGRect(x: s.midX - 150, y: s.minY, width: 300, height: 66)
                fill(rr(isl, 22), rgb(0x000000))
                stroke(rr(isl, 22), rgb(0x3D6BFF), 1.5)
                appIcon(CGRect(x: isl.minX + 14, y: isl.minY + 16, width: 34, height: 34), 0x34C759, "message.fill")
                text("Mum", 14, .semibold, white, x: isl.minX + 58, y: isl.minY + 14)
                let full = "Dinner at 7? 🍞"
                let shown = Int(Double(full.count) * prog(e, 5.4, 6.0))
                text(String(full.prefix(shown)) + cipher(max(0, 8 - shown), Int(e * 20)).prefix(max(0, full.count - shown)), 13, .regular, rgb(0xFFFFFF, 0.8), x: isl.minX + 58, y: isl.minY + 34)
            }
        })
    }

    // the shared key: born between the devices, then one copy into each
    let keyBorn = easeOut(prog(e, 1.2, 1.7)), keySplit = smoother(prog(e, 1.8, 2.5)), keyFade = 1 - easeIn(prog(e, 2.6, 3.0))
    if keyBorn > 0 && keyFade > 0 {
        alpha(keyBorn * keyFade) {
            let center = CGPoint(x: W / 2, y: 545)
            for (i, target) in [CGPoint(x: phone.midX, y: phone.midY), CGPoint(x: mac.midX, y: mac.minY + mac.height * 0.4)].enumerated() {
                let p = lerpP(center, target, keySplit)
                glow(p, 90, rgb(0x3D6BFF, 0.5))
                fill(circle(p, 34), rgb(0x0B0D14)); stroke(circle(p, 34), rgb(0x8A9BFF), 2)
                symbol("key.fill", 28, rgb(0xFFFFFF), p)
                _ = i
            }
        }
    }

    // the message as ciphertext, locked, travelling across
    let fly = prog(e, 3.4, 5.3)
    if fly > 0 && fly < 1 {
        let ease = smoother(fly)
        let a = CGPoint(x: phone.midX, y: phone.midY), b = CGPoint(x: mac.midX, y: mac.minY + 60)
        let p = CGPoint(x: mix(a.x, b.x, ease), y: mix(a.y, b.y, ease) - 220 * sin(.pi * ease))
        // trail
        for k in 1...14 {
            let q = smoother(max(0, fly - Double(k) * 0.018))
            let tp = CGPoint(x: mix(a.x, b.x, q), y: mix(a.y, b.y, q) - 220 * sin(.pi * q))
            fill(circle(tp, 7 - Double(k) * 0.4), rgb(0x3D6BFF, 0.5 * (1 - Double(k) / 15)))
        }
        glow(p, 120, rgb(0x3D6BFF, 0.45))
        let chip = CGRect(x: p.x - 170, y: p.y - 32, width: 340, height: 64)
        fill(rr(chip, 32), rgb(0x0E1222))
        ctx.saveGState(); ctx.addPath(rr(chip, 32)); ctx.setLineWidth(2); ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(gradient(accent), start: CGPoint(x: chip.minX, y: 0), end: CGPoint(x: chip.maxX, y: 0), options: []); ctx.restoreGState()
        symbol("lock.fill", 22, white, CGPoint(x: chip.minX + 36, y: chip.midY))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 20, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.9)]
        NSAttributedString(string: cipher(20, Int(e * 24)), attributes: attrs).draw(at: CGPoint(x: chip.minX + 62, y: chip.minY + 19))
    }
    // the lock opens on arrival
    let open = window(e, 5.2, 5.9, 0.15)
    if open > 0 {
        alpha(open) {
            let p = CGPoint(x: mac.midX, y: mac.minY - 40)
            glow(p, 90, rgb(0x34C759, 0.4))
            symbol("lock.open.fill", 34, rgb(0x34C759), p)
        }
    }

    // no cloud: the path stays between the devices
    let local = easeOut(prog(e, 6.8, 7.4)) * (1 - easeIn(prog(e, 9.4, 9.9)))
    if local > 0 {
        alpha(local) {
            let c = CGPoint(x: W / 2, y: 330)
            symbol("cloud", 120, rgb(0xFFFFFF, 0.25), c, weight: .light)
            let slash = CGMutablePath(); slash.move(to: CGPoint(x: c.x - 90, y: c.y - 70)); slash.addLine(to: CGPoint(x: c.x + 90, y: c.y + 70))
            stroke(slash, rgb(0xFF453A), 6)
            // a direct, glowing link between the devices
            let y = 560.0
            let pulse = (e * 0.8).truncatingRemainder(dividingBy: 1)
            ctx.saveGState(); ctx.setLineDash(phase: -pulse * 40, lengths: [14, 12])
            let link = CGMutablePath(); link.move(to: CGPoint(x: phone.maxX + 30, y: y)); link.addLine(to: CGPoint(x: mac.minX - 70, y: y))
            stroke(link, rgb(0x00C6FF, 0.9), 4); ctx.restoreGState()
            let mid = CGPoint(x: (phone.maxX + mac.minX) / 2 - 20, y: y)
            fill(rr(CGRect(x: mid.x - 120, y: y + 26, width: 240, height: 44), 22), rgb(0xFFFFFF, 0.08))
            text("Wi-Fi · Bluetooth · USB", 18, .medium, rgb(0xFFFFFF, 0.85), x: mid.x, y: y + 37, align: .center)
        }
    }
}

func mainFrame(_ time: Double) {
    t = time
    background()

    // title card
    let title = 1 - easeInOut(prog(t, 2.6, 3.1))
    if title > 0 {
        alpha(title) {
            let p = back(prog(t, 0.2, 0.9)), c = CGPoint(x: W / 2, y: 400)
            scaled(0.6 + 0.4 * p, c) { shadowed(50, 0.25, 20) { icon(CGRect(x: c.x - 110, y: c.y - 110, width: 220, height: 220)) } }
            let a1 = easeOut(prog(t, 0.6, 1.1)), a2 = easeOut(prog(t, 0.9, 1.4))
            alpha(a1) { text("Hop", 96, .bold, ink, x: W / 2, y: 540 + (1 - a1) * 20, align: .center, kern: -2.5) }
            alpha(a2) { gradText("Your Android, right in your Mac's notch.", 40, .medium, x: W / 2, y: 670 + (1 - a2) * 20) }
        }
    }

    // the recording
    let rec = easeOut(prog(t, 2.9, 3.6)) * (1 - easeInOut(prog(t, 40.2, 40.8)))
    if rec > 0 {
        alpha(rec) {
            let f = frameRect().offsetBy(dx: 0, dy: (1 - rec) * 60)
            shadowed(70, 0.28, 30) { fill(rr(f, 18), black) }
            clipped(rr(f, 18)) {
                let (z, fx0, fy0) = zoomAt(t)
                let k = f.width / SW
                // keep the zoomed view inside the screen
                let fx = clamp(fx0, SW / (2 * z), SW - SW / (2 * z)), fy = clamp(fy0, SH / (2 * z), SH - SH / (2 * z))
                ctx.saveGState()
                ctx.translateBy(x: f.midX, y: f.midY)
                ctx.scaleBy(x: k * z, y: k * z)
                ctx.translateBy(x: -fx, y: -fy)
                screenContent()
                ctx.restoreGState()
            }
            stroke(rr(f, 18), rgb(0x000000, 0.08), 1)
        }
    }

    // the phone beside the Mac
    let ps = phoneShift()
    if ps > 0 {
        let c = CGPoint(x: mix(W + 200, frameRect().maxX + 190, ps), y: 590)
        // buzz during the call
        let buzz = window(t, 18.8, 20.2, 0.1)
        let bc = CGPoint(x: c.x + buzz * 3 * sin(t * 120), y: c.y)
        // near rings
        let ringsOn = window(t, 4.8, 6.8, 0.3)
        if ringsOn > 0 {
            for i in 0..<3 {
                let ph = ((t - 4.8) * 0.7 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let r = 120 + 260 * ph
                stroke(circle(bc, r), rgb(0x3D6BFF, ringsOn * 0.5 * (1 - ph)), 2.5)
            }
        }
        phoneMockup(bc, scale: 0.82) { s, rad in
            phoneScreen(s, radius: rad)
            // received file
            let got = window(t, 33.6, 35.0, 0.3)
            alpha(got) {
                let k = s.width / 260
                let b = CGRect(x: s.minX + 8 * k, y: s.minY + 30 * k, width: s.width - 16 * k, height: 64 * k)
                clipped(rr(s, rad)) {
                    fill(rr(b, 16 * k), rgb(0xFFFFFF, 0.97))
                    icon(CGRect(x: b.minX + 10 * k, y: b.minY + 16 * k, width: 26 * k, height: 26 * k))
                    text("Received from Mac", 10 * k, .semibold, ink2, x: b.minX + 44 * k, y: b.minY + 12 * k)
                    text("Boarding pass.pdf", 13 * k, .semibold, ink, x: b.minX + 44 * k, y: b.minY + 30 * k)
                }
            }
            // dims while shown on the Mac
            let dim = easeInOut(prog(t, 8.0, 8.6)) * (1 - easeInOut(prog(t, 18.5, 18.7))) + easeInOut(prog(t, 20.5, 20.9)) * (1 - easeInOut(prog(t, 22.6, 22.8)))
                + easeInOut(prog(t, 24.3, 24.7)) * (1 - easeInOut(prog(t, 27.7, 27.9))) + easeInOut(prog(t, 30.0, 30.4)) * (1 - easeInOut(prog(t, 33.5, 33.6)))
            clipped(rr(s, rad)) { fillR(s, rgb(0, 0.82 * clamp(dim))) }
        }
        alpha(window(t, 4.6, 7.4, 0.4)) {
            let chip = CGRect(x: c.x - 92, y: c.y + 268, width: 184, height: 36)
            fill(rr(chip, 18), white)
            symbol("dot.radiowaves.left.and.right", 13, hopBlue, CGPoint(x: chip.minX + 22, y: chip.midY))
            text("Near your Mac", 14, .semibold, ink, x: chip.minX + 38, y: chip.minY + 9)
        }
    }

    // headlines
    headline(3.4, 9.3, "Bring your phone near.", "It appears on your Mac.")
    headline(9.6, 14.2, "Notifications in the notch.", "Reply in a click.")
    headline(14.5, 18.2, "Click a notification.", "It opens on your phone.")
    headline(18.5, 22.2, "Incoming call?", "Answer from your Mac.")
    headline(22.5, 27.0, "One clipboard.", "Copy there, paste here.")
    headline(27.3, 31.6, "Verification codes.", "Already copied.")
    headline(31.9, 35.4, "Drop files", "straight onto your phone.")
    headline(35.8, 40.0, "Dock mode.", "Your phone as a full desktop.")

    // keycaps
    let kc1 = window(t, 25.0, 26.1, 0.25)
    keycaps(["⌘", "V"], at: CGPoint(x: frameRect().midX, y: 960), kc1)
    let kc2 = window(t, 29.2, 30.2, 0.25)
    keycaps(["⌘", "V"], at: CGPoint(x: frameRect().midX, y: 960), kc2)
    let kc3 = window(t, 12.0, 13.3, 0.25) * 0 // typing shows in the island itself
    _ = kc3
    let kc4 = window(t, 13.3, 13.9, 0.2)
    keycaps(["return"], at: CGPoint(x: frameRect().midX, y: 960), kc4)

    // feature recap
    let recap = window(t, 40.7, 43.0, 0.5)
    if recap > 0 {
        alpha(recap) {
            text("Everything your Android was missing on a Mac.", 46, .semibold, ink, x: W / 2, y: 170, align: .center, kern: -0.8)
            let items: [(String, String)] = [("iphone.radiowaves.left.and.right", "Phone on your Mac"), ("bell.badge.fill", "Notifications & replies"),
                                             ("phone.fill", "Calls"), ("doc.on.clipboard.fill", "Universal clipboard"), ("key.fill", "Codes, auto-copied"),
                                             ("arrow.down.doc.fill", "Files, both ways"), ("macwindow", "Dock mode"), ("lock.fill", "Encrypted · no cloud")]
            for (i, it) in items.enumerated() {
                let a = easeOut(prog(t, 40.9 + Double(i) * 0.08, 41.3 + Double(i) * 0.08))
                alpha(a) {
                    let col = Double(i % 4), row = Double(i / 4)
                    let r = CGRect(x: W / 2 - 860 + col * 435, y: 300 + row * 250 + (1 - a) * 20, width: 415, height: 220)
                    shadowed(30, 0.12, 12) { fill(rr(r, 26), white) }
                    fill(circle(CGPoint(x: r.minX + 62, y: r.minY + 70), 34), rgb(0x3D6BFF, 0.1))
                    symbol(it.0, 30, hopBlue, CGPoint(x: r.minX + 62, y: r.minY + 70))
                    text(it.1, 26, .semibold, ink, x: r.minX + 30, y: r.minY + 140)
                }
            }
        }
    }
    // outro
    if t > 42.8 {
        let a = easeOut(prog(t, 42.9, 43.4)), p = back(prog(t, 42.9, 43.6))
        alpha(a) {
            let c = CGPoint(x: W / 2, y: 330)
            scaled(0.6 + 0.4 * p, c) { shadowed(50, 0.25, 20) { icon(CGRect(x: c.x - 100, y: c.y - 100, width: 200, height: 200)) } }
            text("Hop", 88, .bold, ink, x: W / 2, y: 460, align: .center, kern: -2)
            gradText("Free & open source for macOS and Android", 36, .medium, x: W / 2, y: 580)
            let pill = CGRect(x: W / 2 - 230, y: 670, width: 460, height: 76)
            fill(rr(pill, 38), ink)
            text("mr-vero.github.io/hop", 30, .semibold, white, x: W / 2, y: 690, align: .center)
        }
    }
}

// MARK: - output

func draw(in c: CGContext, time: Double) {
    c.translateBy(x: 0, y: H); c.scaleBy(x: 1, y: -1)
    ctx = c
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
    frame(time)
    NSGraphicsContext.restoreGraphicsState()
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--stills", args.count >= 3 {
    let dir = URL(fileURLWithPath: args[2])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for tm in args[1].split(separator: ",").compactMap({ Double($0) }) {
        let c = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        draw(in: c, time: tm)
        try! NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(String(format: "s%05.1f.png", tm)))
    }
    exit(0)
}

let out = URL(fileURLWithPath: args.first ?? "Hop-showcase.mp4")
try? FileManager.default.removeItem(at: out)
let writer = try! AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
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
        draw(in: c, time: Double(i) / FPS)
        CVPixelBufferUnlockBaseAddress(pb!, [])
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(FPS)))
        if i % 90 == 0 { print("frame \(i)/\(frames)"); fflush(stdout) }
    }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "wrote \(out.path)" : "failed: \(String(describing: writer.error))")
