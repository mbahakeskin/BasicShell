import AppKit
import CoreImage

// usage: eclipse out.png mode(corona|rays|crescent) topHex bottomHex lightHex
let args = CommandLine.arguments
let outPath = args[1], top = args[3], bottom = args[4], light = args[5]
func colour(_ hex: String, _ a: CGFloat = 1) -> CGColor {
    var h = hex; if h.hasPrefix("#") { h.removeFirst() }
    let v = UInt32(h, radix: 16)!
    return CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
}
let S = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext()
func newContext() -> CGContext {
    CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func blur(_ image: CGImage, _ radius: Double) -> CGImage {
    let input = CIImage(cgImage: image).clampedToExtent()
    let out = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
    return ci.createCGImage(out, from: CGRect(x: 0, y: 0, width: S, height: S))!
}
func squircle(_ rect: CGRect, n: CGFloat = 4.4) -> CGPath {
    let path = CGMutablePath(); let a = rect.width / 2, b = rect.height / 2
    for i in 0...360 {
        let t = CGFloat(i) / 360 * 2 * .pi, c = cos(t), s = sin(t)
        let p = CGPoint(x: rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n), y: rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath(); return path
}
func gradient(_ colours: [CGColor], _ at: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cs, colors: colours as CFArray, locations: at)! }
let full = CGRect(x: 0, y: 0, width: S, height: S)
let shape = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))
// usage extra: args[6] = thickness of the crescent at its middle
let thick = CGFloat(Double(args.count > 6 ? args[6] : "70")!)
let R = CGFloat(Double(args.count > 7 ? args[7] : "214")!)    // the dark disc
let Rl = CGFloat(Double(args.count > 8 ? args[8] : "232")!)   // the light disc behind it
let gap = thick - (Rl - R)                 // how far the dark one sits to the right of the light one
let shift = (gap + R - Rl) / 2             // centre what shows: from the crescent's left edge to the dark disc's right edge
let tilt = CGFloat(Double(args.count > 9 ? args[9] : "0")!) * .pi / 180     // 0: horns to the right; negative: opening toward the lower right
let rayCount = Int(args.count > 10 ? args[10] : "12")!
let corona = CGFloat(Double(args.count > 11 ? args[11] : "0")!)   // the soft ring of light round the dark disc, 0...1
let u = CGPoint(x: cos(tilt), y: sin(tilt))   // from the light disc toward the dark one
let lightC = CGPoint(x: 512 - u.x * shift, y: 512 - u.y * shift)
let darkC = CGPoint(x: lightC.x + u.x * gap, y: lightC.y + u.y * gap)

let scene = newContext()
scene.addPath(shape); scene.clip()
scene.drawLinearGradient(gradient([colour(top), colour(bottom)], [0, 1]), start: CGPoint(x: 300, y: 924), end: CGPoint(x: 720, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
scene.setBlendMode(.screen)
// the light is wider than what shows of it: a wash round the whole thing, leaning left
scene.drawRadialGradient(gradient([colour(light, 0.55), colour(light, 0.18), colour(light, 0)], [0, 0.45, 1]), startCenter: lightC, startRadius: 0, endCenter: lightC, endRadius: 470, options: [])
// the corona: light round the dark disc, brightest right at its edge, as in an eclipse
if corona > 0 {
    scene.setBlendMode(.screen)
    scene.drawRadialGradient(gradient([colour(light, 0), colour(light, 0.95 * corona), colour(light, 0.42 * corona), colour(light, 0.12 * corona), colour(light, 0)], [0, 0.0, 0.16, 0.5, 1]),
                             startCenter: darkC, startRadius: R - 6, endCenter: darkC, endRadius: R + 330, options: [])
    scene.setBlendMode(.normal)
}
// the rays: from the light, mostly away from the dark disc, blurred and fading with distance
do {
    let rays = newContext()
    var seed: UInt64 = 7
    func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 1000) / 1000 }
    for i in 0..<rayCount {
        let deg = CGFloat(i) * 360 / CGFloat(rayCount) + (rnd() - 0.5) * 14 + 8
        let rad = deg * .pi / 180
        // facing the dark disc, a ray is behind it anyway; away from it, it carries
        let away = (1 - cos(rad - tilt)) / 2
        let strength = 0.35 + 0.65 * away
        let hw = 1.2 + rnd() * 2.4 + away * 1.1
        let a1 = rad - hw * .pi / 180, a2 = rad + hw * .pi / 180
        rays.setFillColor(CGColor(gray: 1, alpha: min(1, strength * (0.35 + 0.65 * rnd()))))
        rays.move(to: lightC)
        rays.addLine(to: CGPoint(x: lightC.x + 1000 * cos(a1), y: lightC.y + 1000 * sin(a1)))
        rays.addLine(to: CGPoint(x: lightC.x + 1000 * cos(a2), y: lightC.y + 1000 * sin(a2)))
        rays.closePath(); rays.fillPath()
    }
    let mask = blur(rays.makeImage()!, 4.5)
    let lit = newContext()
    lit.clip(to: full, mask: mask)
    lit.drawRadialGradient(gradient([colour(light, 1), colour(light, 0.55), colour(light, 0)], [0, 0.36, 1]), startCenter: lightC, startRadius: Rl - 10, endCenter: lightC, endRadius: 560, options: [])
    scene.setBlendMode(.screen)
    scene.draw(lit.makeImage()!, in: full)
}
scene.setBlendMode(.normal)
let sceneImage = scene.makeImage()!

let final = newContext()
final.saveGState()
final.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: 0.45))
final.addPath(shape); final.setFillColor(colour(bottom)); final.fillPath()
final.restoreGState()
final.draw(sceneImage, in: full)
final.addPath(shape); final.clip()

let lightRect = CGRect(x: lightC.x - Rl, y: lightC.y - Rl, width: Rl * 2, height: Rl * 2)
let darkRect = CGRect(x: darkC.x - R, y: darkC.y - R, width: R * 2, height: R * 2)
let darkPath = CGPath(ellipseIn: darkRect, transform: nil)
let crescent = CGMutablePath()
crescent.addEllipse(in: lightRect)
crescent.addPath(darkPath)
// the glow the crescent throws
final.saveGState()
final.setBlendMode(.screen)
final.setShadow(offset: .zero, blur: 60, color: colour(light, 0.95))
final.addPath(crescent); final.setFillColor(colour(light, 0.7)); final.fillPath(using: .evenOdd)
final.restoreGState()
// the crescent itself: nearly white where it is thickest, amber toward the horns
final.saveGState()
final.addPath(crescent); final.clip(using: .evenOdd)
final.drawRadialGradient(gradient([CGColor(srgbRed: 1, green: 0.96, blue: 0.86, alpha: 1), colour(light, 1), colour(light, 0.86)], [0, 0.5, 1]),
                         startCenter: CGPoint(x: lightC.x - u.x * Rl * 0.55, y: lightC.y - u.y * Rl * 0.55), startRadius: 0, endCenter: CGPoint(x: lightC.x - u.x * Rl * 0.55, y: lightC.y - u.y * Rl * 0.55), endRadius: Rl * 1.25, options: [.drawsAfterEndLocation])
final.restoreGState()

if corona > 0 {
    final.saveGState()
    final.setBlendMode(.screen)
    final.setShadow(offset: .zero, blur: 34, color: colour(light, 0.9 * corona))
    final.addPath(darkPath); final.setFillColor(colour(light, 0.5 * corona)); final.fillPath()
    final.restoreGState()
}
// the dark glass disc in front
final.saveGState()
final.addPath(darkPath); final.clip()
final.drawLinearGradient(gradient([colour(top), colour(bottom)], [0, 1]), start: CGPoint(x: darkC.x - R * 0.6, y: darkC.y + R), end: CGPoint(x: darkC.x + R * 0.6, y: darkC.y - R), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
final.setBlendMode(.screen)
// the light seeping through the glass, strongest on the left where it is
final.drawRadialGradient(gradient([colour(light, 0.30), colour(light, 0)], [0, 1]), startCenter: CGPoint(x: darkC.x - u.x * R, y: darkC.y - u.y * R), startRadius: 0, endCenter: CGPoint(x: darkC.x - u.x * R, y: darkC.y - u.y * R), endRadius: R * 1.1, options: [])
final.setBlendMode(.normal)
final.drawLinearGradient(gradient([CGColor(gray: 1, alpha: 0.20), CGColor(gray: 1, alpha: 0.03), CGColor(gray: 1, alpha: 0)], [0, 0.5, 1]),
                         start: CGPoint(x: darkRect.minX, y: darkRect.maxY), end: CGPoint(x: darkRect.maxX, y: darkRect.minY), options: [])
final.restoreGState()
// the dark disc's edge: warm on the left, glass-white on the top
final.saveGState()
final.addPath(darkPath); final.setLineWidth(3.2); final.replacePathWithStrokedPath(); final.clip()
final.drawLinearGradient(gradient([colour(light, 0.95), CGColor(gray: 1, alpha: 0.55), colour(light, 0.18 + 0.6 * corona)], [0, 0.45, 1]),
                         start: CGPoint(x: darkC.x - u.x * R, y: darkC.y - u.y * R), end: CGPoint(x: darkC.x + u.x * R, y: darkC.y + u.y * R), options: [])
final.restoreGState()
let rep = NSBitmapImageRep(cgImage: final.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote", outPath)
