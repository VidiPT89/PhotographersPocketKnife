import XCTest
import CoreImage
@testable import PhotographersPocketKnife

final class DevelopTests: XCTestCase {

    func testRecipesFromOlderVersionsStillDecode() throws {
        let legacy = Data(#"{"exposure":0.5,"contrast":0.2,"crop":{"x":0.1,"y":0,"width":0.8,"height":1}}"#.utf8)
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: legacy)
        XCTAssertEqual(recipe.exposure, 0.5)
        XCTAssertEqual(recipe.crop.x, 0.1)
        XCTAssertEqual(recipe.sharpenRadius, 1, "Missing fields fall back to defaults")
        XCTAssertEqual(recipe.grainSize, 0.5)
        XCTAssertTrue(recipe.masks.isEmpty)

        var full = EditRecipe()
        full.clarity = 0.4
        full.masks = [LocalMask(kind: .radial)]
        full.shadowsSaturation = 0.6
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(full)), full)

        let history = try JSONDecoder().decode(EditHistory.self, from: Data(#"{"entries":[{"labelKey":"history.original","recipe":{}}],"index":0}"#.utf8))
        XCTAssertTrue(history.snapshots.isEmpty)
    }

    func testColorGradingTintsShadowsNotHighlights() {
        var recipe = EditRecipe()
        recipe.shadowsHue = 240
        recipe.shadowsSaturation = 1
        let dark = ColorCube.applyGrading((0.1, 0.1, 0.1), recipe)
        XCTAssertGreaterThan(dark.2, dark.0, "Shadows pick up blue")
        let bright = ColorCube.applyGrading((0.95, 0.95, 0.95), recipe)
        XCTAssertEqual(bright.2, bright.0, accuracy: 1e-9, "Highlights stay neutral")
        XCTAssertTrue(recipe.needsToneCube)
    }

    func testRadialMaskAffectsCentreOnly() throws {
        let gray = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        var recipe = EditRecipe()
        var mask = LocalMask(kind: .radial)
        mask.radiusX = 0.2
        mask.radiusY = 0.2
        mask.feather = 0.2
        mask.exposure = 2
        recipe.masks = [mask]
        let output = ImageRenderer.shared.apply(recipe, to: gray)
        XCTAssertGreaterThan(try pixel(output, at: CGPoint(x: 200, y: 150)).r, 0.5)
        XCTAssertEqual(try pixel(output, at: CGPoint(x: 5, y: 5)).r, try pixel(gray, at: CGPoint(x: 5, y: 5)).r, accuracy: 0.01)

        recipe.masks[0].invert = true
        let inverted = ImageRenderer.shared.apply(recipe, to: gray)
        XCTAssertGreaterThan(try pixel(inverted, at: CGPoint(x: 5, y: 5)).r, 0.5)
    }

    func testLinearMaskFadesAlongTheGradient() throws {
        let gray = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        var recipe = EditRecipe()
        var mask = LocalMask(kind: .linear)
        mask.startX = 0.5; mask.startY = 0
        mask.endX = 0.5; mask.endY = 0.5
        mask.exposure = -2
        recipe.masks = [mask]
        let output = ImageRenderer.shared.apply(recipe, to: gray)
        // Coordenadas Core Image: y = 395 é o topo da imagem.
        XCTAssertLessThan(try pixel(output, at: CGPoint(x: 200, y: 395)).r, 0.15, "Top is darkened")
        XCTAssertEqual(try pixel(output, at: CGPoint(x: 200, y: 20)).r, 0.3, accuracy: 0.02, "Bottom half untouched")
    }

    func testPresenceDetailOpticsAndEffectsRender() throws {
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputWidth": 8, "inputColor0": CIColor(red: 0.8, green: 0.6, blue: 0.4), "inputColor1": CIColor(red: 0.2, green: 0.3, blue: 0.5),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        var recipe = EditRecipe()
        recipe.clarity = 0.7
        recipe.texture = -0.5
        recipe.sharpness = 0.6
        recipe.sharpenMasking = 0.5
        recipe.colorNoiseReduction = 0.5
        recipe.chromaticAberration = 0.8
        recipe.grain = 0.6
        let output = ImageRenderer.shared.apply(recipe, to: checker)
        XCTAssertEqual(output.extent, checker.extent, "Every stage keeps the image size")
        let rendered = try XCTUnwrap(ImageRenderer.shared.context.createCGImage(output, from: output.extent))
        XCTAssertEqual(rendered.width, 300)
    }

    func testClippingIsMeasuredAndHighlighted() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        context.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 50, width: 100, height: 50))
        let image = try XCTUnwrap(context.makeImage())

        let histogram = Histogram.compute(image)
        XCTAssertEqual(histogram.clippedHighlights, 0.5, accuracy: 0.02)
        XCTAssertEqual(histogram.clippedShadows, 0, accuracy: 0.001)

        let overlay = try XCTUnwrap(ClippingOverlay.make(from: image))
        XCTAssertEqual(overlay.width, 100)
    }

    @MainActor
    func testSnapshotsAndMasksLiveInTheEditingModel() {
        let model = EditingModel()
        model.recipe.exposure = 1
        model.saveSnapshot(named: "Look A")
        XCTAssertEqual(model.history.snapshots.first?.name, "Look A")
        model.recipe.exposure = -1
        model.applySnapshot(model.history.snapshots[0])
        XCTAssertEqual(model.recipe.exposure, 1)

        model.addMask(.linear)
        XCTAssertEqual(model.recipe.masks.count, 1)
        XCTAssertEqual(model.selectedMaskIndex, 0)
        model.deleteMask(model.recipe.masks[0].id)
        XCTAssertNil(model.selectedMaskIndex)
    }

    private func pixel(_ image: CIImage, at point: CGPoint) throws -> (r: Float, g: Float, b: Float) {
        var bytes = [Float](repeating: 0, count: 4)
        ImageRenderer.shared.context.render(image, toBitmap: &bytes, rowBytes: 16, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                                            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (bytes[0], bytes[1], bytes[2])
    }
}
