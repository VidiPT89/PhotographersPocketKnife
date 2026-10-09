// Gera o ícone da app a partir do logótipo (`assets/logo.jpg`).
// O ícone usa só o emblema: o nome escrito por baixo seria ilegível a 16–32 px.
// Uso: swift scripts/make-icon.swift assets/logo.jpg App/Resources/Assets.xcassets
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("Uso: swift scripts/make-icon.swift <logótipo> <Assets.xcassets>")
    exit(1)
}
let logoURL = URL(fileURLWithPath: arguments[1])
let assets = URL(fileURLWithPath: arguments[2], isDirectory: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

guard let source = CGImageSourceCreateWithURL(logoURL as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("Não foi possível ler \(logoURL.path)")
    exit(1)
}

// Emblema no logótipo de 2048 px (origem no canto superior esquerdo): margem para a seta à direita,
// e o corte em baixo fica acima do nome escrito.
let scale = CGFloat(logo.width) / 2048
let emblemRect = CGRect(x: 395 * scale, y: 290 * scale, width: 1210 * scale, height: 1115 * scale)
let emblem = logo.cropping(to: emblemRect.integral)!

func context(_ width: Int, _ height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    return ctx
}

/// Máscara em tons de cinzento: opaca no centro, a desvanecer nas orlas, para o recorte não se notar.
func featherMask(width: Int, height: Int, feather: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let w = CGFloat(width), h = CGFloat(height)
    for step in 0..<Int(feather) {
        let inset = CGFloat(step)
        let t = inset / feather
        ctx.setFillColor(gray: t * t * (3 - 2 * t), alpha: 1)
        ctx.fill(CGRect(x: inset, y: inset, width: w - inset * 2, height: h - inset * 2))
    }
    return ctx.makeImage()!
}

/// Cor média de um canto do logótipo: o fundo do ícone continua o do próprio logótipo.
func backgroundColor() -> CGColor {
    let ctx = context(1, 1)
    ctx.draw(logo.cropping(to: CGRect(x: 40 * scale, y: 40 * scale, width: 160 * scale, height: 160 * scale))!,
             in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return CGColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
}

func drawEmblem(in ctx: CGContext, rect: CGRect, feather: CGFloat) {
    let mask = featherMask(width: emblem.width, height: emblem.height, feather: feather)
    ctx.saveGState()
    ctx.clip(to: rect, mask: mask)
    ctx.draw(emblem, in: rect)
    ctx.restoreGState()
}

func fitted(_ size: CGSize, in box: CGRect) -> CGRect {
    let factor = min(box.width / size.width, box.height / size.height)
    let fit = CGSize(width: size.width * factor, height: size.height * factor)
    return CGRect(x: box.midX - fit.width / 2, y: box.midY - fit.height / 2, width: fit.width, height: fit.height)
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Não foi possível escrever \(url.path)") }
}

func resized(_ image: CGImage, to size: Int) -> CGImage {
    let ctx = context(size, size)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

// Ícone: grelha do macOS, forma de 824 px centrada em 1024, raio ~185, com sombra.
let iconCtx = context(1024, 1024)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
iconCtx.saveGState()
iconCtx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
iconCtx.addPath(bodyPath)
iconCtx.setFillColor(backgroundColor())
iconCtx.fillPath()
iconCtx.restoreGState()
iconCtx.saveGState()
iconCtx.addPath(bodyPath)
iconCtx.clip()
drawEmblem(in: iconCtx, rect: fitted(CGSize(width: emblem.width, height: emblem.height), in: body.insetBy(dx: 30, dy: 30)), feather: 60 * scale)
iconCtx.restoreGState()
let icon = iconCtx.makeImage()!

let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
for size in [16, 32, 64, 128, 256, 512] {
    write(resized(icon, to: size), to: iconSet.appendingPathComponent("icon_\(size).png"))
}
write(icon, to: iconSet.appendingPathComponent("icon_512@2x.png"))

print("Ícone gerado a partir de \(logoURL.lastPathComponent).")
