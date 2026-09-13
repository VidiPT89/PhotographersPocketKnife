// Gera o ícone da app (1024 px) — diafragma âmbar sobre fundo escuro, cores de ividi.dev.
// Uso: swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Grelha de ícones do macOS: forma de 824 px centrada, raio ~185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x0A0A0F)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x24242E), rgb(0x0A0A0F)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xD97706, 0.55), rgb(0xD97706, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 500), startRadius: 0, endCenter: CGPoint(x: 512, y: 500), endRadius: 420, options: [])
ctx.restoreGState()

// Diafragma de 6 lâminas.
let center = CGPoint(x: 512, y: 512)
let radius: CGFloat = 270
let inner: CGFloat = radius * 0.4
let twist = Double.pi / 14
func p(_ r: CGFloat, _ a: Double) -> CGPoint { CGPoint(x: center.x + r * CGFloat(cos(a)), y: center.y + r * CGFloat(sin(a))) }
let blades = CGMutablePath()
for i in 0..<6 {
    let a = Double(i) * .pi / 3 + .pi / 6, b = a + .pi / 3
    blades.move(to: p(radius, a))
    blades.addArc(center: center, radius: radius, startAngle: CGFloat(a), endAngle: CGFloat(b), clockwise: false)
    blades.addLine(to: p(inner, b + twist))
    blades.addLine(to: p(inner, a + twist))
    blades.closeSubpath()
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: rgb(0xF59E0B, 0.55))
ctx.addPath(blades); ctx.setFillColor(rgb(0xD97706)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(blades); ctx.clip()
let bladeGradient = CGGradient(colorsSpace: space, colors: [rgb(0xFBBF24), rgb(0xF59E0B), rgb(0xB45309)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bladeGradient, start: CGPoint(x: 300, y: 780), end: CGPoint(x: 720, y: 240), options: [])
ctx.restoreGState()
ctx.addPath(blades); ctx.setStrokeColor(rgb(0x0A0A0F, 0.55)); ctx.setLineWidth(7); ctx.strokePath()

// Anel exterior com reflexo.
ctx.saveGState()
ctx.setLineWidth(14)
ctx.addEllipse(in: CGRect(x: center.x - radius - 22, y: center.y - radius - 22, width: (radius + 22) * 2, height: (radius + 22) * 2))
ctx.replacePathWithStrokedPath(); ctx.clip()
let ring = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.85), rgb(0xF59E0B, 0.35), rgb(0xB45309, 0.2)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(ring, start: CGPoint(x: 512, y: 820), end: CGPoint(x: 512, y: 200), options: [])
ctx.restoreGState()

// Contorno subtil da forma.
ctx.addPath(bodyPath); ctx.setStrokeColor(rgb(0xFFFFFF, 0.08)); ctx.setLineWidth(3); ctx.strokePath()

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let image = ctx.makeImage()!
let master = out.appendingPathComponent("icon_1024.png")
let dest = CGImageDestinationCreateWithURL(master as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
print(master.path)
