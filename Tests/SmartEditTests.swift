import XCTest
import CoreImage
import ImageIO
@testable import PhotographersPocketKnife

struct SplitMix64Test {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class SmartEditTests: XCTestCase {

    // MARK: Remoção de objetos

    func testInpainterFillsHoleWithSurroundingTexture() throws {
        let width = 96, height = 96
        var pixels = [Float](repeating: 0, count: width * height * 3)
        var hole = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let stripe: Float = ((x + y) / 6) % 2 == 0 ? 0.3 : 0.6
                pixels[i * 3] = stripe * 0.5; pixels[i * 3 + 1] = stripe; pixels[i * 3 + 2] = stripe * 0.7
                if abs(x - 48) < 12, abs(y - 48) < 12 {
                    hole[i] = true
                    pixels[i * 3] = 1; pixels[i * 3 + 1] = 0; pixels[i * 3 + 2] = 0
                }
            }
        }
        let image = Inpainter.Image(width: width, height: height, pixels: pixels)
        let field = Inpainter.solve(image, hole: hole)
        XCTAssertFalse(field.targets.isEmpty)
        let filled = Inpainter.fill(image, hole: hole, field: field)

        var red: Float = 0, green: Float = 0, count: Float = 0
        for i in 0..<(width * height) where hole[i] {
            red += filled.pixels[i * 3]; green += filled.pixels[i * 3 + 1]; count += 1
        }
        XCTAssertLessThan(red / count, 0.35, "The red square is gone")
        XCTAssertEqual(green / count, 0.45, accuracy: 0.12, "Filled with the stripes' colours")
        XCTAssertEqual(filled.pixels[0], pixels[0], "Pixels outside the hole stay untouched")

        // A média da cor sozinha não prova nada: uma mancha lisa da cor certa passava nas linhas acima,
        // e foi exatamente isso que a remoção entregou durante meses. A textura tem de lá estar.
        func energy(_ p: [Float], _ x0: Int, _ y0: Int, _ side: Int) -> Float {
            var total: Float = 0
            for y in y0..<(y0 + side - 1) {
                for x in x0..<(x0 + side - 1) {
                    let i = (y * width + x) * 3 + 1
                    let dx = p[i] - p[i + 3], dy = p[i] - p[((y + 1) * width + x) * 3 + 1]
                    total += dx * dx + dy * dy
                }
            }
            return total / Float((side - 1) * (side - 1))
        }
        let inside = energy(filled.pixels, 40, 40, 16)
        let outside = energy(filled.pixels, 8, 8, 16)
        XCTAssertGreaterThan(inside, outside * 0.5, "The hole carries real texture, not the average colour")
    }

    func testRemovalErasesPaintedObjectThroughThePipeline() throws {
        let photo = CIImage(cgImage: try stripedImage(square: CGRect(x: 60, y: 110, width: 40, height: 40)))
        var recipe = EditRecipe()
        // Centro do quadrado em coordenadas normalizadas com origem em cima: (80/240, 1 - 130/180).
        recipe.removals = [Removal(strokes: [BrushStroke(points: [CurvePoint(x: 80.0 / 240, y: 1 - 130.0 / 180)], size: 0.38)])]

        let output = ImageRenderer.shared.apply(recipe, to: photo)
        let centre = try pixel(output, at: CGPoint(x: 80, y: 130))
        XCTAssertLessThan(centre.r, centre.g, "The red square was replaced by the green background")
        let far = try pixel(output, at: CGPoint(x: 200, y: 20))
        let original = try pixel(photo, at: CGPoint(x: 200, y: 20))
        XCTAssertEqual(far.g, original.g, accuracy: 0.01, "Outside the removal nothing changes")

        // Mexer num slider reaproveita as correspondências e continua sem o objeto.
        recipe.exposure = 0.5
        let brighter = try pixel(ImageRenderer.shared.apply(recipe, to: photo), at: CGPoint(x: 80, y: 130))
        XCTAssertLessThan(brighter.r, brighter.g)
    }

    func testRemovalKeepsTheTextureSharpOnALargePhoto() throws {
        // Numa foto grande a zona a preencher é muito maior do que o lado de trabalho do `Inpainter`.
        // O preenchimento tem de ser copiado na resolução da região, senão chega ao ecrã como um borrão.
        let square = CGRect(x: 960, y: 660, width: 480, height: 480)
        let photo = CIImage(cgImage: try finelyStripedImage(width: 2400, height: 1800, period: 10, square: square))
        var recipe = EditRecipe()
        recipe.removals = [Removal(strokes: [BrushStroke(points: [CurvePoint(x: 0.5, y: 0.5)], size: 0.3)])]

        let output = ImageRenderer.shared.apply(recipe, to: photo)
        let centre = try pixel(output, at: CGPoint(x: 1200, y: 900))
        XCTAssertLessThan(centre.r, centre.g, "The red square was replaced by the striped background")

        let filled = try detail(output, in: CGRect(x: 1080, y: 780, width: 240, height: 240))
        let control = try detail(output, in: CGRect(x: 300, y: 300, width: 240, height: 240))
        XCTAssertGreaterThan(filled, control * 0.7, "The filled area keeps the texture of its surroundings")
    }

    func testRemovalsAndSubjectMasksSurviveCodableAndPresets() throws {
        var recipe = EditRecipe()
        recipe.removals = [Removal(objectPoint: CurvePoint(x: 0.4, y: 0.6)), Removal(strokes: [BrushStroke(points: [CurvePoint(x: 0.1, y: 0.1)])])]
        recipe.masks = [LocalMask(kind: .subject)]
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe)), recipe)

        var preset = EditRecipe()
        preset.exposure = 1
        preset.removals = [Removal(objectPoint: CurvePoint(x: 0.9, y: 0.9))]
        let applied = recipe.applyingSettings(from: preset)
        XCTAssertEqual(applied.removals, recipe.removals, "A preset never brings removals from another photo")
        XCTAssertEqual(applied.exposure, 1)
    }

    func testSubjectMaskWithoutSubjectLeavesThePhotoAlone() throws {
        let gray = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 150))
        var mask = LocalMask(kind: .subject)
        mask.exposure = 2
        var recipe = EditRecipe()
        recipe.masks = [mask]
        let output = ImageRenderer.shared.apply(recipe, to: gray)
        XCTAssertEqual(try pixel(output, at: CGPoint(x: 100, y: 75)).r, 0.4, accuracy: 0.02)
    }

    // MARK: Edição automática

    func testAutoEnhanceBrightensDarkPhotoAndNeutralisesColourCast() throws {
        // Riscas cinzentas (neutras de verdade), escuras e com dominante azul.
        let dark = try stripedImage(square: nil, brightness: 0.35, cast: (0.8, 0.9, 1.2), gray: true)
        let photo = CIImage(cgImage: dark)
        var recipe = EditRecipe()
        recipe.crop = CropRect(x: 0.1, y: 0, width: 0.8, height: 1)
        recipe.masks = [LocalMask(kind: .radial)]

        let enhanced = AutoEnhance.enhance(recipe, image: photo)
        XCTAssertGreaterThan(enhanced.exposure, 0.3)
        XCTAssertEqual(enhanced.crop, recipe.crop, "Framing is left alone")
        XCTAssertEqual(enhanced.masks, recipe.masks)

        let before = try displayed(photo)
        let after = try displayed(ImageRenderer.shared.apply(enhanced, to: photo, applyCrop: false))
        XCTAssertGreaterThan(after.luminance, before.luminance + 0.1, "The photo gets brighter")
        XCTAssertLessThan(abs(after.blueCast), abs(before.blueCast), "The blue cast is reduced")
    }

    func testAutoEnhanceStraightensATiltedHorizon() throws {
        let tilted = try horizonImage(degrees: 4)
        guard let detected = AutoEnhance.horizonAngle(tilted) else {
            throw XCTSkip("Vision did not detect a horizon in the synthetic image")
        }
        let enhanced = AutoEnhance.enhance(EditRecipe(), image: CIImage(cgImage: tilted))
        XCTAssertEqual(enhanced.straighten, -detected, accuracy: 0.4)

        let straightened = ImageRenderer.shared.apply(enhanced, to: CIImage(cgImage: tilted))
        let rendered = try XCTUnwrap(ImageRenderer.shared.context.createCGImage(straightened, from: straightened.extent))
        let remaining = AutoEnhance.horizonAngle(rendered) ?? 0
        XCTAssertLessThan(abs(remaining), abs(detected), "Applying the suggestion levels the horizon")
    }

    // MARK: Foto real (opcional)

    /// `TEST_RUNNER_PPK_SMART_PHOTO=/caminho/foto.jpg` para ver o Vision e a remoção numa foto verdadeira.
    func testRealPhotoSubjectAndRemoval() throws {
        guard let path = ProcessInfo.processInfo.environment["PPK_SMART_PHOTO"] else { throw XCTSkip("No real photo configured") }
        let url = URL(fileURLWithPath: path)
        let base = try XCTUnwrap(ImageRenderer.shared.previewBase(url: url, maxPixel: 2000, lensCorrection: false))
        let input = CIImage(cgImage: base)

        var start = Date()
        let subject = SmartSelection.shared.subjectMask(for: input)
        print("PPK subject mask:", subject != nil, String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000))

        var recipe = AutoEnhance.enhance(EditRecipe(), image: input)
        print("PPK auto:", recipe.exposure, recipe.temperature, recipe.tint, recipe.contrast, recipe.highlights, recipe.shadows, recipe.vibrance, recipe.straighten)

        recipe.removals = [Removal(objectPoint: CurvePoint(x: 0.5, y: 0.5))]
        start = Date()
        let output = ImageRenderer.shared.apply(recipe, to: input)
        let image = try XCTUnwrap(ImageRenderer.shared.context.createCGImage(output, from: output.extent))
        print("PPK removal render:", String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000))
        if let out = ProcessInfo.processInfo.environment["PPK_SMART_OUTPUT"],
           let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }



    /// Harness visual. Desligado por omissão; correr com
    /// `TEST_RUNNER_PPK_DUMP=<pasta> xcodebuild test -only-testing:.../testDiagnosticCrowd`.
    /// Textura tipo bancada — manchas desfocadas do tamanho de uma cabeça — porque é nela que o
    /// preenchimento se denuncia: num fundo liso qualquer junta é uma aresta onde não devia haver nenhuma.
    func testDiagnosticCrowd() throws {
        guard let out = ProcessInfo.processInfo.environment["PPK_DUMP"] else { throw XCTSkip("no dump dir") }
        let width = 2000, height = 1200
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var state: UInt64 = 99
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        func rnd(_ a: Double, _ b: Double) -> Double { a + Double(next() % 10000) / 10000 * (b - a) }
        ctx.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<9000 {
            let x = rnd(0, Double(width)), y = rnd(0, Double(height))
            let r = rnd(10, 34), tone = rnd(0.08, 0.85)
            ctx.setFillColor(CGColor(red: tone * rnd(0.8, 1.1), green: tone * rnd(0.8, 1.05),
                                     blue: tone * rnd(0.85, 1.15), alpha: rnd(0.35, 0.95)))
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r * rnd(0.9, 1.4)))
        }
        let crowd = try XCTUnwrap(ctx.makeImage())
        let blurred = CIImage(cgImage: crowd).clampedToExtent().applyingGaussianBlur(sigma: 3)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let photo = try XCTUnwrap(ImageRenderer.shared.context.createCGImage(blurred, from: blurred.extent))

        // Pincel de 5%, como o do fotógrafo: a zona é pequena e nem chega a ser reduzida.
        var recipe = EditRecipe()
        recipe.removals = [Removal(strokes: [BrushStroke(points: (0..<4).map {
            CurvePoint(x: (700.0 + Double($0) * 22) / Double(width), y: 1 - (500.0 + Double($0) * 18) / Double(height))
        }, size: 0.05)])]

        let output = ImageRenderer.shared.apply(recipe, to: CIImage(cgImage: photo))
        let result = try XCTUnwrap(ImageRenderer.shared.context.createCGImage(output, from: output.extent))
        for (name, image) in [("crowd_before", photo), ("crowd_after", result)] {
            let url = URL(fileURLWithPath: out).appendingPathComponent("\(name).png")
            let d = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(d, image, nil)
            CGImageDestinationFinalize(d)
        }
    }

    func testRemovalDoesNotDragInContentFromAnotherPartOfThePhoto() throws {
        // Camisola às riscas à esquerda, equipamento azul à direita. Ao apagar uma marca nas riscas,
        // o preenchimento tem de vir das riscas ao lado — nunca do azul, que é outra coisa da foto.
        let width = 1200, height = 800
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in stride(from: 0, to: 800, by: 60) {
            ctx.setFillColor(CGColor(gray: (x / 60) % 2 == 0 ? 0.92 : 0.08, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 60, height: height))
        }
        // O equipamento azul cruza mesmo por cima, como a perna cruza a camisola na foto real.
        ctx.setFillColor(CGColor(red: 0.05, green: 0.42, blue: 0.62, alpha: 1))
        ctx.saveGState()
        ctx.translateBy(x: 600, y: 560)
        ctx.rotate(by: -0.5)
        ctx.fill(CGRect(x: -700, y: -70, width: 1400, height: 140))
        ctx.restoreGState()
        let photo = try XCTUnwrap(ctx.makeImage())

        var recipe = EditRecipe()
        recipe.removals = [Removal(strokes: [BrushStroke(points: (0..<5).map {
            CurvePoint(x: (300.0 + Double($0) * 40) / Double(width), y: 1 - 400.0 / Double(height))
        }, size: 0.05)])]

        let output = ImageRenderer.shared.apply(recipe, to: CIImage(cgImage: photo))
        let box = CGRect(x: 280, y: 360, width: 240, height: 80)
        var rgba = [Float](repeating: 0, count: Int(box.width * box.height) * 4)
        ImageRenderer.shared.context.render(output, toBitmap: &rgba, rowBytes: Int(box.width) * 16, bounds: box,
                                            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        // Azul do outro equipamento: muito mais azul do que vermelho. As riscas são cinzentas neutras.
        let foreign = (0..<Int(box.width * box.height)).filter { rgba[$0 * 4 + 2] > rgba[$0 * 4] + 0.12 }.count
        let share = Double(foreign) / (box.width * box.height)
        XCTAssertLessThan(share, 0.02, "The fill must not drag the blue kit onto the striped shirt")
    }

    /// Harness visual sobre uma foto verdadeira. `TEST_RUNNER_PPK_PHOTO` aponta o ficheiro,
    /// `TEST_RUNNER_PPK_DUMP` a pasta de saída, `TEST_RUNNER_PPK_STROKE` os pontos normalizados
    /// (origem em cima) como "x1,y1;x2,y2;...", e `TEST_RUNNER_PPK_BRUSH` o tamanho do pincel.
    func testDiagnosticBrushOnPhoto() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["PPK_DUMP"], let photoPath = env["PPK_PHOTO"], let strokeText = env["PPK_STROKE"] else {
            throw XCTSkip("no photo configured")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: photoPath) as CFURL, nil))
        let photo = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let points = strokeText.split(separator: ";").compactMap { pair -> CurvePoint? in
            let parts = pair.split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
            return CurvePoint(x: x, y: y)  // `CurvePoint.y` já é a fracção a contar de cima
        }
        var recipe = EditRecipe()
        recipe.removals = [Removal(strokes: [BrushStroke(points: points, size: Double(env["PPK_BRUSH"] ?? "") ?? 0.05)])]

        let start = Date()
        let output = ImageRenderer.shared.apply(recipe, to: CIImage(cgImage: photo))
        let result = try XCTUnwrap(ImageRenderer.shared.context.createCGImage(output, from: output.extent))
        print("PPK photo removal: \(photo.width)x\(photo.height) em \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        let url = URL(fileURLWithPath: out).appendingPathComponent("photo_after.png")
        let d = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(d, result, nil)
        CGImageDestinationFinalize(d)
    }

    // MARK: Utilitários

    /// Fundo com riscas diagonais verdes e, opcionalmente, um quadrado vermelho (coordenadas com origem em baixo).
    private func stripedImage(square: CGRect?, brightness: CGFloat = 1, cast: (CGFloat, CGFloat, CGFloat) = (1, 1, 1), gray: Bool = false) throws -> CGImage {
        let width = 240, height = 180
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (index, start) in stride(from: -height, to: width + height, by: 12).enumerated() {
            let base: (CGFloat, CGFloat, CGFloat) = gray
                ? (index % 2 == 0 ? (0.35, 0.35, 0.35) : (0.7, 0.7, 0.7))
                : (index % 2 == 0 ? (0.25, 0.5, 0.3) : (0.45, 0.75, 0.5))
            context.setFillColor(CGColor(red: min(base.0 * brightness * cast.0, 1), green: min(base.1 * brightness * cast.1, 1),
                                         blue: min(base.2 * brightness * cast.2, 1), alpha: 1))
            context.move(to: CGPoint(x: start, y: 0))
            context.addLine(to: CGPoint(x: start + 12, y: 0))
            context.addLine(to: CGPoint(x: start + 12 + height, y: height))
            context.addLine(to: CGPoint(x: start + height, y: height))
            context.fillPath()
        }
        if let square {
            context.setFillColor(CGColor(red: 0.95, green: 0.05, blue: 0.05, alpha: 1))
            context.fill(square)
        }
        return try XCTUnwrap(context.makeImage())
    }

    /// Céu claro em cima, mar escuro em baixo, com a linha do horizonte rodada.
    private func horizonImage(degrees: CGFloat) throws -> CGImage {
        let width = 480, height = 320
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.55, green: 0.75, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: degrees * .pi / 180)
        context.setFillColor(CGColor(red: 0.05, green: 0.2, blue: 0.35, alpha: 1))
        context.fill(CGRect(x: -CGFloat(width), y: -CGFloat(height) * 1.5, width: CGFloat(width) * 2, height: CGFloat(height) * 1.5))
        return try XCTUnwrap(context.makeImage())
    }

    /// Riscas finas e densas: qualquer perda de nitidez aparece como queda do gradiente médio.
    private func finelyStripedImage(width: Int, height: Int, period: Int, square: CGRect? = nil) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (index, start) in stride(from: -height, to: width + height, by: period).enumerated() {
            let tone: CGFloat = index % 2 == 0 ? 0.28 : 0.72
            context.setFillColor(CGColor(red: tone * 0.6, green: tone, blue: tone * 0.8, alpha: 1))
            context.move(to: CGPoint(x: start, y: 0))
            context.addLine(to: CGPoint(x: start + period, y: 0))
            context.addLine(to: CGPoint(x: start + period + height, y: height))
            context.addLine(to: CGPoint(x: start + height, y: height))
            context.fillPath()
        }
        if let square {
            context.setFillColor(CGColor(red: 0.95, green: 0.05, blue: 0.05, alpha: 1))
            context.fill(square)
        }
        return try XCTUnwrap(context.makeImage())
    }

    /// Energia do gradiente (ao quadrado) numa zona: mede a nitidez. Ao contrário do gradiente médio,
    /// não se conserva quando uma aresta é espalhada por vários píxeis — é isso que distingue nítido de borrado.
    private func detail(_ image: CIImage, in region: CGRect) throws -> Float {
        let width = Int(region.width), height = Int(region.height)
        var rgba = [Float](repeating: 0, count: width * height * 4)
        ImageRenderer.shared.context.render(image, toBitmap: &rgba, rowBytes: width * 16, bounds: region,
                                            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var total: Float = 0
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let i = (y * width + x) * 4
                let dx = rgba[i + 1] - rgba[i + 5], dy = rgba[i + 1] - rgba[((y + 1) * width + x) * 4 + 1]
                total += dx * dx + dy * dy
            }
        }
        return total / Float((width - 1) * (height - 1))
    }

    private func pixel(_ image: CIImage, at point: CGPoint) throws -> (r: Float, g: Float, b: Float) {
        var bytes = [Float](repeating: 0, count: 4)
        ImageRenderer.shared.context.render(image, toBitmap: &bytes, rowBytes: 16, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                                            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (bytes[0], bytes[1], bytes[2])
    }

    /// Médias como aparecem no ecrã (sRGB, cada píxel limitado a 0…1). O azul é relativo ao brilho.
    private func displayed(_ image: CIImage) throws -> (luminance: Float, blueCast: Float) {
        let e = image.extent.integral
        let width = Int(e.width), height = Int(e.height)
        var rgba = [Float](repeating: 0, count: width * height * 4)
        ImageRenderer.shared.context.render(image, toBitmap: &rgba, rowBytes: width * 16, bounds: e, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var r: Float = 0, g: Float = 0, b: Float = 0
        for i in 0..<(width * height) {
            r += min(max(rgba[i * 4], 0), 1); g += min(max(rgba[i * 4 + 1], 0), 1); b += min(max(rgba[i * 4 + 2], 0), 1)
        }
        let n = Float(width * height)
        r /= n; g /= n; b /= n
        return (0.2126 * r + 0.7152 * g + 0.0722 * b, 3 * (b - r) / max(r + g + b, 1e-4))
    }
}
