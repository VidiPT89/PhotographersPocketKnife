import XCTest
import CoreImage
import ImageIO
@testable import PhotographersPocketKnife

/// Remoção sobre fotos verdadeiras e pelo modelo generativo: harness de diagnóstico e verificação de ponta a
/// ponta. Nada disto corre por omissão — dependem de fotos locais ou do modelo descarregado.
final class RemovalDiagnosticTests: XCTestCase {

    override func tearDown() {
        GenerativeInpainter.shared.isEnabled = true
        super.tearDown()
    }

    /// Harness visual sobre uma foto verdadeira. `TEST_RUNNER_PPK_PHOTO` aponta o ficheiro,
    /// `TEST_RUNNER_PPK_DUMP` a pasta de saída, `TEST_RUNNER_PPK_STROKE` os pontos normalizados
    /// (origem em cima) como "x1,y1;x2,y2;...", e `TEST_RUNNER_PPK_BRUSH` o tamanho do pincel.
    func testDiagnosticBrushOnPhoto() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["PPK_DUMP"], let photoPath = env["PPK_PHOTO"],
              let strokeText = env["PPK_STROKE"] ?? env["PPK_OBJECT"] else {
            throw XCTSkip("no photo configured")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: photoPath) as CFURL, nil))
        let photo = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let points = strokeText.split(separator: ";").compactMap { pair -> CurvePoint? in
            let parts = pair.split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
            return CurvePoint(x: x, y: y)  // `CurvePoint.y` já é a fracção a contar de cima
        }
        GenerativeInpainter.shared.isEnabled = env["PPK_COPY"] == nil
        var recipe = EditRecipe()
        if let object = env["PPK_OBJECT"]?.split(separator: ","), object.count == 2,
           let ox = Double(object[0]), let oy = Double(object[1]) {
            recipe.removals = [Removal(objectPoint: CurvePoint(x: ox, y: oy))]
        } else {
            recipe.removals = [Removal(strokes: [BrushStroke(points: points, size: Double(env["PPK_BRUSH"] ?? "") ?? 0.05)])]
        }

        if env["PPK_PROBE"] != nil {
            let input = CIImage(cgImage: photo)
            for y in stride(from: 0.15, through: 0.95, by: 0.1) {
                var row = ""
                for x in stride(from: 0.05, through: 0.95, by: 0.05) {
                    row += SmartSelection.shared.objectMask(for: input, at: CurvePoint(x: x, y: y)) != nil ? "#" : "."
                }
                print(String(format: "PPK probe y=%.2f %@", y, row))
            }
        }

        let start = Date()
        let output = ImageRenderer.shared.apply(recipe, to: CIImage(cgImage: photo))
        let result = try XCTUnwrap(ImageRenderer.shared.context.createCGImage(output, from: output.extent))
        print("PPK photo removal: \(photo.width)x\(photo.height) em \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        let url = URL(fileURLWithPath: out).appendingPathComponent("photo_after.png")
        let d = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(d, result, nil)
        CGImageDestinationFinalize(d)
    }

    /// Verifica o caminho generativo de ponta a ponta, pelo pipeline real. Instala o modelo se preciso
    /// (descarrega 99 MB), por isso só corre com `TEST_RUNNER_PPK_GENERATIVE=1`.
    func testGenerativeRemovalErasesLetteringThroughThePipeline() async throws {
        guard ProcessInfo.processInfo.environment["PPK_GENERATIVE"] != nil else { throw XCTSkip("generative off") }
        GenerativeInpainter.shared.isEnabled = true
        if !GenerativeInpainter.shared.isInstalled {
            try await GenerativeInpainter.shared.install { _ in }
        }
        XCTAssertTrue(GenerativeInpainter.shared.isReady)

        let width = 1200, height = 800
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Faixa escura com letras claras: o caso em que copiar falha sempre, porque a vizinhança das
        // letras são as outras letras.
        ctx.setFillColor(CGColor(gray: 0.07, alpha: 1))
        ctx.fill(CGRect(x: 200, y: 280, width: 800, height: 260))
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
        for i in 0..<7 {
            ctx.fill(CGRect(x: 260 + i * 100, y: 380, width: 46, height: 90))
            ctx.fill(CGRect(x: 260 + i * 100, y: 380, width: 70, height: 22))
        }
        let photo = try XCTUnwrap(ctx.makeImage())

        var recipe = EditRecipe()
        recipe.removals = [Removal(strokes: [BrushStroke(points: (0..<8).map {
            CurvePoint(x: (285.0 + Double($0) * 100) / Double(width), y: 1 - 425.0 / Double(height))
        }, size: 0.14)])]

        let started = Date()
        let output = ImageRenderer.shared.apply(recipe, to: CIImage(cgImage: photo))
        print("PPK generative render: \(Int(Date().timeIntervalSince(started) * 1000)) ms")

        // Dentro da faixa, onde estavam as letras, já não pode haver nada claro.
        let box = CGRect(x: 250, y: 370, width: 700, height: 110)
        var rgba = [Float](repeating: 0, count: Int(box.width * box.height) * 4)
        ImageRenderer.shared.context.render(output, toBitmap: &rgba, rowBytes: Int(box.width) * 16, bounds: box,
                                            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let bright = (0..<Int(box.width * box.height)).filter { rgba[$0 * 4 + 1] > 0.5 }.count
        let share = Double(bright) / (box.width * box.height)
        print("PPK generative bright share: \(share)")
        XCTAssertLessThan(share, 0.05, "The lettering is gone, not redrawn from its own neighbours")

        // Fora da faixa nada se mexe. Comparado com a própria origem: `CGColor(gray:)` é cinzento
        // genérico e não sRGB, por isso o valor lido não é o que se escreveu.
        let far = try pixel(output, at: CGPoint(x: 80, y: 700))
        let farOriginal = try pixel(CIImage(cgImage: photo), at: CGPoint(x: 80, y: 700))
        XCTAssertEqual(far.g, farOriginal.g, accuracy: 0.01, "Outside the removal nothing changes")

        // Segunda passagem, com o modelo já carregado: é este o tempo que o fotógrafo sente.
        let warm = Date()
        _ = ImageRenderer.shared.apply(recipe, to: CIImage(cgImage: photo))
        print("PPK generative warm render: \(Int(Date().timeIntervalSince(warm) * 1000)) ms")

        if let out = ProcessInfo.processInfo.environment["PPK_DUMP"] {
            let image = try XCTUnwrap(ImageRenderer.shared.context.createCGImage(output, from: output.extent))
            for (name, cg) in [("gen_before", photo), ("gen_after", image)] {
                let url = URL(fileURLWithPath: out).appendingPathComponent("\(name).png")
                let d = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(d, cg, nil)
                CGImageDestinationFinalize(d)
            }
        }
    }

    private func pixel(_ image: CIImage, at point: CGPoint) throws -> (r: Float, g: Float, b: Float) {
        var rgba = [Float](repeating: 0, count: 4)
        ImageRenderer.shared.context.render(image, toBitmap: &rgba, rowBytes: 16, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                                            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (rgba[0], rgba[1], rgba[2])
    }
}
