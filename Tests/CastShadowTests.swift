import XCTest
import CoreImage
@testable import PhotographersPocketKnife

final class CastShadowTests: XCTestCase {

    /// Chão de areia (liso, com grão fino), um objecto claro de pé e, se `shadow`, a sombra dele colada aos pés.
    private func scene(shadow: Bool, groundGrain: CGFloat = 0.03, blurredBackground: Bool = false) throws -> (photo: CIImage, object: CIImage) {
        let width = 900, height = 600
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var rng = SplitMix64Test(state: 42)
        for y in stride(from: 0, to: height, by: 3) {
            for x in stride(from: 0, to: width, by: 3) {
                let n = CGFloat(rng.next() % 1000) / 1000 * groundGrain
                ctx.setFillColor(CGColor(srgbRed: 0.78 + n, green: 0.70 + n, blue: 0.55 + n, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 3, height: 3))
            }
        }
        if blurredBackground {
            // Fundo escuro que escurece aos poucos, como uma bancada desfocada.
            for x in 0..<width {
                let t = CGFloat(x) / CGFloat(width)
                ctx.setFillColor(CGColor(srgbRed: 0.35 - 0.25 * t, green: 0.33 - 0.23 * t, blue: 0.40 - 0.22 * t, alpha: 1))
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: 250))
            }
        }
        // Objecto: um rectângulo claro de pé, com a base em y = 250 (origem em baixo).
        let body = CGRect(x: 400, y: 250, width: 90, height: 220)
        if shadow {
            // Sombra azulada e de berma nítida, estendida para a direita a partir da base.
            ctx.setFillColor(CGColor(srgbRed: 0.20, green: 0.22, blue: 0.30, alpha: 1))
            ctx.fill(CGRect(x: 400, y: 215, width: 300, height: 38))
        }
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1))
        ctx.fill(body)
        let photo = CIImage(cgImage: try XCTUnwrap(ctx.makeImage()))
        let object = CIImage(color: .white).cropped(to: body).composited(over: CIImage(color: .black).cropped(to: photo.extent))
        return (photo, object)
    }

    private func value(_ mask: CIImage, at point: CGPoint) -> Float {
        var px = [Float](repeating: 0, count: 4)
        ImageRenderer.shared.context.render(mask, toBitmap: &px, rowBytes: 16, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                                            format: .RGBAf, colorSpace: nil)
        return px[0]
    }

    func testFindsTheSharpShadowAtTheFeetOnSmoothGround() throws {
        let (photo, object) = try scene(shadow: true)
        let shadow = try XCTUnwrap(CastShadow.mask(for: object, in: photo), "A sharp shadow on sand is found")
        XCTAssertGreaterThan(value(shadow, at: CGPoint(x: 600, y: 234)), 0.5, "The shadow's far end is taken")
        XCTAssertLessThan(value(shadow, at: CGPoint(x: 600, y: 400)), 0.1, "Lit sand is not")
        XCTAssertLessThan(value(shadow, at: CGPoint(x: 445, y: 400)), 0.1, "The object itself is not part of the shadow")
    }

    func testTakesNothingWithoutAShadow() throws {
        let (photo, object) = try scene(shadow: false)
        XCTAssertNil(CastShadow.mask(for: object, in: photo))
    }

    /// Um fundo escuro que escurece aos poucos parece sombra na cor e no brilho, mas não tem berma nítida.
    func testSoftDarkBackgroundIsNotAShadow() throws {
        let (photo, object) = try scene(shadow: false, blurredBackground: true)
        XCTAssertNil(CastShadow.mask(for: object, in: photo))
    }

    /// Em chão com muita textura (água, terra com ervas) não se arrisca.
    func testTexturedGroundIsLeftAlone() throws {
        let (photo, object) = try scene(shadow: true, groundGrain: 0.45)
        XCTAssertNil(CastShadow.mask(for: object, in: photo))
    }
}
