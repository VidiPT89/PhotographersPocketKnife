// Gera o ícone da app (1024 px): um olho cuja íris é o diafragma de uma objetiva, cores de ividi.dev.
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
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xD97706, 0.45), rgb(0xD97706, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 440, options: [])
ctx.restoreGState()

let center = CGPoint(x: 512, y: 512)

// Contorno do olho: duas curvas que se encontram nos cantos.
let halfWidth: CGFloat = 330
let lid: CGFloat = 250
let eye = CGMutablePath()
eye.move(to: CGPoint(x: center.x - halfWidth, y: center.y))
eye.addCurve(to: CGPoint(x: center.x + halfWidth, y: center.y),
             control1: CGPoint(x: center.x - halfWidth * 0.45, y: center.y + lid), control2: CGPoint(x: center.x + halfWidth * 0.45, y: center.y + lid))
eye.addCurve(to: CGPoint(x: center.x - halfWidth, y: center.y),
             control1: CGPoint(x: center.x + halfWidth * 0.45, y: center.y - lid), control2: CGPoint(x: center.x - halfWidth * 0.45, y: center.y - lid))
eye.closeSubpath()

// Branco do olho escuro, com brilho âmbar vindo da íris.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 50, color: rgb(0xF59E0B, 0.35))
ctx.addPath(eye); ctx.setFillColor(rgb(0x15151C)); ctx.fillPath()
ctx.restoreGState()

// Íris = diafragma de 6 lâminas, cortado pelas pálpebras.
let radius: CGFloat = 178
let inner: CGFloat = radius * 0.36
let twist = Double.pi / 12
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
ctx.addPath(eye); ctx.clip()
// Anel da íris.
ctx.addEllipse(in: CGRect(x: center.x - radius - 14, y: center.y - radius - 14, width: (radius + 14) * 2, height: (radius + 14) * 2))
ctx.setFillColor(rgb(0x0A0A0F)); ctx.fillPath()
ctx.saveGState()
ctx.addPath(blades); ctx.clip()
let bladeGradient = CGGradient(colorsSpace: space, colors: [rgb(0xFBBF24), rgb(0xF59E0B), rgb(0xB45309)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bladeGradient, start: CGPoint(x: 360, y: 700), end: CGPoint(x: 660, y: 320), options: [])
ctx.restoreGState()
ctx.addPath(blades); ctx.setStrokeColor(rgb(0x0A0A0F, 0.6)); ctx.setLineWidth(6); ctx.strokePath()
// Pupila: o hexágono aberto no centro, com fundo quase preto.
let pupil = CGMutablePath()
for i in 0..<6 {
    let point = p(inner * 0.98, Double(i) * .pi / 3 + .pi / 6 + twist)
    if i == 0 { pupil.move(to: point) } else { pupil.addLine(to: point) }
}
pupil.closeSubpath()
ctx.addPath(pupil); ctx.setFillColor(rgb(0x050507)); ctx.fillPath()
// Anel metálico da objetiva à volta da íris.
ctx.saveGState()
ctx.setLineWidth(12)
ctx.addEllipse(in: CGRect(x: center.x - radius - 10, y: center.y - radius - 10, width: (radius + 10) * 2, height: (radius + 10) * 2))
ctx.replacePathWithStrokedPath(); ctx.clip()
let ring = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.85), rgb(0xF59E0B, 0.4), rgb(0xB45309, 0.25)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(ring, start: CGPoint(x: 512, y: 700), end: CGPoint(x: 512, y: 320), options: [])
ctx.restoreGState()
// Reflexo de luz na córnea.
ctx.addEllipse(in: CGRect(x: center.x - 92, y: center.y + 58, width: 46, height: 46))
ctx.setFillColor(rgb(0xFFFFFF, 0.9)); ctx.fillPath()
ctx.addEllipse(in: CGRect(x: center.x - 38, y: center.y + 108, width: 18, height: 18))
ctx.setFillColor(rgb(0xFFFFFF, 0.6)); ctx.fillPath()
ctx.restoreGState()

// Pálpebras: contorno com gradiente branco → âmbar.
ctx.saveGState()
ctx.setLineWidth(26)
ctx.setLineJoin(.round)
ctx.addPath(eye)
ctx.replacePathWithStrokedPath(); ctx.clip()
let lids = CGGradient(colorsSpace: space, colors: [rgb(0xFFF7E6), rgb(0xFBBF24), rgb(0xD97706)] as CFArray, locations: [0, 0.45, 1])!
ctx.drawLinearGradient(lids, start: CGPoint(x: 512, y: 780), end: CGPoint(x: 512, y: 240), options: [])
ctx.restoreGState()

// Contorno subtil da forma.
ctx.addPath(bodyPath); ctx.setStrokeColor(rgb(0xFFFFFF, 0.08)); ctx.setLineWidth(3); ctx.strokePath()

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let image = ctx.makeImage()!
let master = out.appendingPathComponent("icon_1024.png")
let dest = CGImageDestinationCreateWithURL(master as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
print(master.path)
