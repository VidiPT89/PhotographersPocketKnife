import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotographersPocketKnife

/// Regressões no pipeline de cor falham de forma visível: a imagem de referência é comparada com tolerância ΔE.
/// Para atualizar a referência de propósito: `TEST_RUNNER_PPK_UPDATE_GOLDEN=1 xcodebuild test …`
final class GoldenImageTests: XCTestCase {
    private var referenceURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden/develop-reference.png")
    }

    func testDevelopPipelineMatchesReference() throws {
        let rendered = try render()
        if ProcessInfo.processInfo.environment["PPK_UPDATE_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: referenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(referenceURL as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, rendered, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            throw XCTSkip("Golden reference updated at \(referenceURL.path)")
        }

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(referenceURL as CFURL, nil), "Missing reference: run with PPK_UPDATE_GOLDEN=1")
        let reference = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(rendered.width, reference.width)
        XCTAssertEqual(rendered.height, reference.height)

        let a = try rgba(rendered), b = try rgba(reference)
        var total = 0.0, worst = 0.0
        for i in stride(from: 0, to: a.count, by: 4) {
            let delta = deltaE(Self.lab(a[i], a[i + 1], a[i + 2]), Self.lab(b[i], b[i + 1], b[i + 2]))
            total += delta
            worst = max(worst, delta)
        }
        let mean = total / Double(a.count / 4)
        XCTAssertLessThan(mean, 1.0, "Mean ΔE \(mean)")
        XCTAssertLessThan(worst, 8.0, "Worst pixel ΔE \(worst)")
    }

    private func render() throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: 360, height: 240)
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 360, y: 240),
            "inputColor0": CIColor(red: 0.85, green: 0.45, blue: 0.1), "inputColor1": CIColor(red: 0.1, green: 0.3, blue: 0.75),
        ])!.outputImage!
        let spot = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 120, y: 150), "inputRadius0": 10, "inputRadius1": 90,
            "inputColor0": CIColor(red: 1, green: 1, blue: 0.9, alpha: 0.9), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])!.outputImage!
        let input = spot.composited(over: gradient).cropped(to: extent)

        var recipe = EditRecipe()
        recipe.exposure = 0.35
        recipe.contrast = 0.3
        recipe.highlights = -0.4
        recipe.shadows = 0.3
        recipe.whites = 0.2
        recipe.blacks = -0.1
        recipe.temperature = 0.2
        recipe.vibrance = 0.3
        recipe.clarity = 0.3
        recipe.curveMaster = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.2), CurvePoint(x: 0.75, y: 0.82), CurvePoint(x: 1, y: 1)]
        recipe.hsl[HSLBand.blue.rawValue].saturation = -0.5
        recipe.shadowsSaturation = 0.4
        recipe.vignette = -0.3
        recipe.crop = CropRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        recipe.straighten = 2

        let output = ImageRenderer.shared.apply(recipe, to: input)
        return try XCTUnwrap(ImageRenderer.shared.context.createCGImage(output, from: output.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn)
        return pixels
    }

    private func deltaE(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
    }

    /// sRGB 8 bits → CIE Lab (D65).
    static func lab(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (Double, Double, Double) {
        func linear(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let (lr, lg, lb) = (linear(r), linear(g), linear(b))
        let x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047
        let y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
        let z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }
}
