import XCTest
import CoreImage
import ImageIO
@testable import PhotographersPocketKnife

/// Bancada de ensaio da remoção generativa: apaga zonas de fotos verdadeiras onde se sabe o que lá estava
/// e compara. Não é um teste de passa/falha — corre só com `TEST_RUNNER_PPK_BENCH=<pasta de fotos>` e
/// imprime números, para afinar `GenerativeInpainter.Tuning` com medidas em vez de a olho.
///
/// Duas medidas por zona apagada, ambas contra o original:
/// - **forma**: erro médio depois de desfocar os dois (σ = 3 px) — cor e estrutura, sem o grão;
/// - **detalhe**: energia do detalhe fino do preenchimento a dividir pela do original. 1 é o certo; abaixo
///   é liso de mais, acima é ruído a mais. Conta como `|log(razão)|`.
///
/// `TEST_RUNNER_PPK_BENCH_CONFIG` escolhe a afinação, ex. `context=2.6,margin=0.15,detail=1,blur=0.6,grain=1`.
final class RemovalBenchmarkTests: XCTestCase {

    func testBenchmarkGenerativeRemoval() throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["PPK_BENCH"], GenerativeInpainter.shared.isInstalled else { throw XCTSkip("no benchmark") }
        let saved = (GenerativeInpainter.Tuning.context, GenerativeInpainter.Tuning.strokeMargin, GenerativeInpainter.Tuning.detail,
                     GenerativeInpainter.Tuning.detailBlur, GenerativeInpainter.Tuning.grain, GenerativeInpainter.Tuning.detailFromGain)
        defer {
            (GenerativeInpainter.Tuning.context, GenerativeInpainter.Tuning.strokeMargin, GenerativeInpainter.Tuning.detail,
             GenerativeInpainter.Tuning.detailBlur, GenerativeInpainter.Tuning.grain, GenerativeInpainter.Tuning.detailFromGain) = saved
            ObjectRemover.shared.clearCaches()
        }
        for pair in (env["PPK_BENCH_CONFIG"] ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=")
            guard kv.count == 2, let value = Double(kv[1]) else { continue }
            switch kv[0] {
            case "context": GenerativeInpainter.Tuning.context = value
            case "margin": GenerativeInpainter.Tuning.strokeMargin = value
            case "detail": GenerativeInpainter.Tuning.detail = value != 0
            case "blur": GenerativeInpainter.Tuning.detailBlur = value
            case "grain": GenerativeInpainter.Tuning.grain = value != 0
            case "gain": GenerativeInpainter.Tuning.detailFromGain = value
            default: break
            }
        }
        GenerativeInpainter.shared.isEnabled = true
        ObjectRemover.shared.clearCaches()

        let files = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".png") }.sorted()
        var shapes: [Double] = [], details: [Double] = []
        let started = Date()
        for (index, name) in files.enumerated() {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let photo = CIImage(cgImage: try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
            var rng = SplitMix64Test(state: UInt64(index + 1) &* 0x9E37)
            func random(_ low: Double, _ high: Double) -> Double { low + Double(rng.next() % 10_000) / 10_000 * (high - low) }
            // Três manchas redondas de tamanhos diferentes e um traço, em sítios ao acaso longe das bordas.
            var holes: [BrushStroke] = [0.08, 0.18, 0.32].map { size in
                BrushStroke(points: [CurvePoint(x: random(0.2, 0.8), y: random(0.25, 0.75))], size: size)
            }
            let y = random(0.3, 0.7), x = random(0.15, 0.4)
            holes.append(BrushStroke(points: [CurvePoint(x: x, y: y), CurvePoint(x: x + 0.2, y: y + random(-0.1, 0.1)),
                                              CurvePoint(x: x + 0.4, y: y)], size: 0.05))
            for (k, stroke) in holes.enumerated() {
                var recipe = EditRecipe()
                recipe.removals = [Removal(strokes: [stroke])]
                let output = ImageRenderer.shared.apply(recipe, to: photo)
                guard let mask = ImageRenderer.rasterizeStrokes([stroke], extent: photo.extent)?.image else { continue }
                let (shape, detail) = measure(output, against: photo, inside: mask)
                shapes.append(shape); details.append(detail)
                print(String(format: "PPKBENCH %@ #%d shape %.4f detail %.2f", name, k, shape, detail))
            }
        }
        let meanShape = shapes.reduce(0, +) / Double(max(shapes.count, 1))
        let meanDetail = details.map { abs(log(max($0, 1e-3))) }.reduce(0, +) / Double(max(details.count, 1))
        print(String(format: "PPKBENCH RESULT %@ shape %.4f detailLog %.3f n %d in %.0f s", env["PPK_BENCH_CONFIG"] ?? "default",
                     meanShape, meanDetail, shapes.count, Date().timeIntervalSince(started)))
    }

    /// Erro de forma e razão de detalhe fino dentro de `mask` (branco = zona apagada).
    private func measure(_ output: CIImage, against original: CIImage, inside mask: CIImage) -> (Double, Double) {
        let e = original.extent
        let context = ImageRenderer.shared.context
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        func pixels(_ image: CIImage) -> [Float] {
            var buffer = [Float](repeating: 0, count: Int(e.width) * Int(e.height) * 4)
            context.render(image.cropped(to: e), toBitmap: &buffer, rowBytes: Int(e.width) * 16, bounds: e, format: .RGBAf, colorSpace: space)
            return buffer
        }
        func blurred(_ image: CIImage) -> CIImage { image.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: e) }
        let w = Int(e.width), h = Int(e.height)
        let hole = pixels(mask), out = pixels(output), ref = pixels(original)
        let outSmooth = pixels(blurred(output)), refSmooth = pixels(blurred(original))
        var error = 0.0, count = 0.0, outFine = 0.0, refFine = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where hole[(y * w + x) * 4] > 0.99 {
                let i = (y * w + x) * 4
                for c in 0..<3 { error += Double(abs(outSmooth[i + c] - refSmooth[i + c])) }
                count += 3
                func lap(_ p: [Float]) -> Double {
                    var total = 0.0
                    for c in 0..<3 {
                        let v = 4 * p[i + c] - p[i + c - 4] - p[i + c + 4] - p[i + c - w * 4] - p[i + c + w * 4]
                        total += Double(v * v)
                    }
                    return total
                }
                outFine += lap(out); refFine += lap(ref)
            }
        }
        return (error / max(count, 1), outFine / max(refFine, 1e-9))
    }
}
