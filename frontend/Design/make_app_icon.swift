// Renders the 1024×1024 app icon: two dark poster cards fanned behind a gold-to-red card marked "#1",
// on the app's dark background with a warm glow. From frontend/:
//   swift Design/make_app_icon.swift "Movie List/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

// Theme colours (Helpers/Theme.swift)
let gold = rgb(0.98, 0.76, 0.27), red = rgb(0.93, 0.29, 0.36)

// Background: the app's near-black, a touch lighter at the top
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0.10, 0.10, 0.15), rgb(0.03, 0.03, 0.06)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Warm glow behind the cards
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0.96, 0.52, 0.31, 0.55), rgb(0.93, 0.29, 0.36, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size / 2, y: size * 0.47), startRadius: 0,
                       endCenter: CGPoint(x: size / 2, y: size * 0.47), endRadius: size * 0.46, options: [])

let cardW: CGFloat = 350, cardH: CGFloat = 525, radius: CGFloat = 48
let center = CGPoint(x: size / 2, y: size / 2 - 6)

func card(angle: CGFloat, dx: CGFloat, dy: CGFloat, scale: CGFloat, draw: (CGRect) -> Void) {
    ctx.saveGState()
    ctx.translateBy(x: center.x + dx, y: center.y + dy)
    ctx.rotate(by: angle * .pi / 180)
    ctx.scaleBy(x: scale, y: scale)
    let rect = CGRect(x: -cardW / 2, y: -cardH / 2, width: cardW, height: cardH)
    // Soft drop shadow
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0, 0, 0, 0.6))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(rgb(0.14, 0.14, 0.2))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    draw(rect)
    ctx.restoreGState()
}

// A back card: dark slate with a faint frame and a few "poster" bands
func backCard(_ rect: CGRect) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [rgb(0.24, 0.24, 0.32), rgb(0.13, 0.13, 0.19)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.resetClip()
    ctx.addPath(path); ctx.setStrokeColor(rgb(1, 1, 1, 0.10)); ctx.setLineWidth(4); ctx.strokePath()
}

// Tops lean outwards, like a hand of cards
card(angle: -14, dx: 165, dy: -10, scale: 0.88, draw: backCard)
card(angle: 14, dx: -165, dy: -10, scale: 0.88, draw: backCard)

// Front card: the accent gradient with "#1" punched out in the background colour
card(angle: 0, dx: 0, dy: 10, scale: 1) { rect in
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [gold, red] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // A light sheen across the top
    let sheen = CGGradient(colorsSpace: cs, colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY), options: [])
    ctx.resetClip()

    var font = NSFont.systemFont(ofSize: 262, weight: .black)
    if let rounded = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: rounded, size: 262) ?? font }
    let text = NSAttributedString(string: "#1", attributes: [.font: font, .foregroundColor: NSColor(cgColor: rgb(0.06, 0.06, 0.1))!, .kern: -6])
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetImageBounds(line, ctx)
    ctx.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY - 8)
    CTLineDraw(line, ctx)
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) \(image.width)x\(image.height)")
