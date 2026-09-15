import XCTest
import CoreImage
@testable import PhotographersPocketKnife

final class DenoiseTests: XCTestCase {
    private let context = CIContext()
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    func testSumKeepsNegativeValuesAndOpaqueAlpha() {
        let a = solid(0.3), b = solid(0.5)
        // A matriz com bias no alfa torna a imagem infinita; corta-se para ler um píxel conhecido.
        let difference = WaveletDenoise.sum(a, WaveletDenoise.matrix(b, scale: -1)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let pixel = render(difference, width: 1, height: 1, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        XCTAssertEqual(pixel[0], -0.2, accuracy: 0.001)
        XCTAssertEqual(pixel[3], 1, accuracy: 0.001)
    }

    func testWaveletDenoiseSmoothsGrainButKeepsEdges() throws {
        let width = 256, height = 256
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt64 = 42
        func noise() -> Double {
            var total = 0.0
            for _ in 0..<4 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                total += Double(seed >> 11) / Double(1 << 53) - 0.5
            }
            return total * 0.07
        }
        for y in 0..<height {
            for x in 0..<width {
                let base = x < width / 2 ? 0.25 : 0.75
                let value = UInt8(min(max((base + noise()) * 255, 0), 255))
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                          space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = CIImage(cgImage: image)
        let output = WaveletDenoise.apply(input, strength: 0.8)
        XCTAssertEqual(output.extent, input.extent)

        let before = stats(render(input, width: width, height: height, space: sRGB), width: width)
        let after = stats(render(output, width: width, height: height, space: sRGB), width: width)
        XCTAssertLessThan(after.noise, before.noise * 0.5, "grain \(before.noise) → \(after.noise)")
        XCTAssertGreaterThan(after.edge, before.edge * 0.9, "edge contrast \(before.edge) → \(after.edge)")
        XCTAssertEqual(WaveletDenoise.apply(input, strength: 0).extent, input.extent)
    }

    func testStrengthGrowsWithISO() {
        let values = [nil, 400, 1600, 3200, 6400, 25600].map { WaveletDenoise.suggestedStrength(iso: $0) }
        XCTAssertEqual(values[0], 0.5)
        XCTAssertEqual(Array(values.dropFirst()), Array(values.dropFirst()).sorted())
        XCTAssertLessThanOrEqual(values.max() ?? 0, 1)
    }

    private func solid(_ value: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    private func render(_ image: CIImage, width: Int, height: Int, space: CGColorSpace) -> [Float] {
        var bytes = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bytes, rowBytes: width * 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: image.extent.minX, y: image.extent.minY, width: CGFloat(width), height: CGFloat(height)),
                       format: .RGBAf, colorSpace: space)
        return bytes
    }

    /// Desvio padrão numa zona lisa e diferença média entre as duas metades (contraste da aresta).
    private func stats(_ pixels: [Float], width: Int) -> (noise: Double, edge: Double) {
        func region(_ xs: Range<Int>) -> [Double] {
            (24..<232).flatMap { y in xs.map { x in Double(pixels[(y * width + x) * 4]) } }
        }
        let left = region(24..<100), right = region(156..<232)
        let mean = left.reduce(0, +) / Double(left.count)
        let variance = left.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(left.count)
        let rightMean = right.reduce(0, +) / Double(right.count)
        return (variance.squareRoot(), rightMean - mean)
    }
}
