import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotographersPocketKnife

final class RetouchGalleryTests: XCTestCase {

    // MARK: Retoque

    func testSkinToneMaskFindsSkinAndIgnoresOtherColours() throws {
        let skin = try maskValue(red: 0.85, green: 0.65, blue: 0.55)
        let blue = try maskValue(red: 0.2, green: 0.3, blue: 0.8)
        let grass = try maskValue(red: 0.3, green: 0.6, blue: 0.2)
        XCTAssertGreaterThan(skin, 0.6)
        XCTAssertLessThan(blue, 0.1)
        XCTAssertLessThan(grass, 0.1)
    }

    func testSkinSmoothingSoftensSkinAndLeavesTheRestAlone() throws {
        let image = CIImage(cgImage: try texturedHalves())
        let everyone = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: image.extent)
        var recipe = EditRecipe()
        recipe.skinSmoothing = 1
        let output = Retouch.apply(recipe, to: image, personMask: everyone)

        let skin = CGRect(x: 20, y: 20, width: 80, height: 140), background = CGRect(x: 140, y: 20, width: 80, height: 140)
        XCTAssertLessThan(try variance(output, skin), try variance(image, skin) * 0.6, "Skin texture is softened")
        let before = try variance(image, background)
        XCTAssertEqual(try variance(output, background), before, accuracy: before * 0.1 + 1e-6, "Non-skin colours are untouched")
    }

    func testBackgroundBlurKeepsThePersonSharp() throws {
        let image = CIImage(cgImage: try texturedHalves())
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: image.extent)
        let leftPerson = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 180)).composited(over: black)
        var recipe = EditRecipe()
        recipe.backgroundBlur = 1
        let output = Retouch.apply(recipe, to: image, personMask: leftPerson)

        let person = CGRect(x: 10, y: 20, width: 80, height: 140), background = CGRect(x: 150, y: 20, width: 80, height: 140)
        let personBefore = try variance(image, person)
        XCTAssertEqual(try variance(output, person), personBefore, accuracy: personBefore * 0.1 + 1e-6, "The person stays sharp")
        XCTAssertLessThan(try variance(output, background), try variance(image, background) * 0.5, "The background is blurred")

        // Sem pessoa detetada, nada muda; receitas antigas abrem com os valores a zero.
        XCTAssertEqual(try variance(Retouch.apply(recipe, to: image, personMask: nil), background), try variance(image, background), accuracy: 1e-9)
        let legacy = try JSONDecoder().decode(EditRecipe.self, from: Data(#"{"exposure":0.3}"#.utf8))
        XCTAssertEqual(legacy.skinSmoothing, 0)
        XCTAssertEqual(legacy.backgroundBlur, 0)
    }

    // MARK: Galeria

    func testGalleryBuildsAFlatSiteWithEscapedText() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-gallery-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let originals = folder.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let files = try (1...2).map { index -> URL in
            let url = originals.appendingPathComponent("DSC_000\(index).jpg")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try texturedHalves(), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return url
        }

        var options = GalleryOptions()
        options.title = "Casamento <Ana & Rui>"
        options.photographer = "David"
        options.email = "noivos@example.com"
        let strings = ClientGallery.Strings(lang: "pt-PT", search: "Procurar", favourites: "Favoritas", send: "Enviar", copy: "Copiar",
                                            copied: "Copiada", download: "Descarregar", photos: "fotos", close: "Fechar",
                                            previous: "Anterior", next: "Seguinte", empty: "Nada", by: "por")
        let photos = files.map { GalleryPhoto(url: $0, recipe: EditRecipe(), caption: "</script><b>x</b>", keywords: ["praia"]) }
        let site = folder.appendingPathComponent("site")
        var progressCalls = 0
        let output = try ClientGallery.build(photos, options: options, strings: strings, exportSettings: ExportSettings(), to: site) { _, _ in
            progressCalls += 1
        }

        XCTAssertEqual(progressCalls, 2)
        XCTAssertEqual(Set(output.map(\.lastPathComponent)), ["photo-001.jpg", "thumb-001.jpg", "photo-002.jpg", "thumb-002.jpg", "index.html"])
        XCTAssertTrue(output.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == site.standardizedFileURL }, "Everything in one folder")
        let html = try String(contentsOf: site.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("Casamento &lt;Ana &amp; Rui&gt;"))
        XCTAssertFalse(html.contains("</script><b>"), "A caption cannot break out of the data block")
        XCTAssertTrue(html.contains("thumb-002.jpg"))
        XCTAssertTrue(html.contains("DSC_0001.jpg"))
        let thumb = MetadataReader.basicInfo(for: site.appendingPathComponent("thumb-001.jpg"))
        XCTAssertLessThanOrEqual(max(thumb.width, thumb.height), 640)
    }

    /// `TEST_RUNNER_PPK_GALLERY_DIR` (fotos) + `TEST_RUNNER_PPK_GALLERY_OUT` (pasta) criam uma galeria verdadeira para ver no browser.
    func testRealGallery() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let source = environment["PPK_GALLERY_DIR"], let output = environment["PPK_GALLERY_OUT"] else { throw XCTSkip("No real gallery configured") }
        let photos = PhotoImporter.imageFiles(in: URL(fileURLWithPath: source)).prefix(12).map {
            GalleryPhoto(url: $0, recipe: EditRecipe(), caption: "", keywords: AutoKeywords.suggest(url: $0))
        }
        var options = GalleryOptions()
        options.title = "Sessão de teste"
        options.photographer = "David Arsénio Martins"
        options.email = "cliente@example.com"
        options.website = "ividi.dev"
        let strings = ClientGallery.Strings(lang: "pt-PT", search: "Procurar", favourites: "Favoritas", send: "Enviar favoritas", copy: "Copiar lista",
                                            copied: "Lista copiada", download: "Descarregar", photos: "fotos", close: "Fechar",
                                            previous: "Anterior", next: "Seguinte", empty: "Nenhuma foto encontrada", by: "por")
        let files = try ClientGallery.build(Array(photos), options: options, strings: strings, exportSettings: ExportSettings(),
                                            to: URL(fileURLWithPath: output)) { _, _ in }
        print("PPK gallery files:", files.count, "keywords:", photos.map(\.keywords))
    }

    // MARK: Utilitários

    private func maskValue(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Float {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let mask = Retouch.skinMask(of: CIImage(cgImage: try XCTUnwrap(context.makeImage())))
        var pixel = [Float](repeating: 0, count: 4)
        ImageRenderer.shared.context.render(mask, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 4, y: 4, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return pixel[0]
    }

    /// Metade esquerda em tons de pele, metade direita azul, ambas com textura píxel a píxel.
    private func texturedHalves() throws -> CGImage {
        let width = 240, height = 180
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let delta = (x + y) % 2 == 0 ? 18 : -18
                let base: (Int, Int, Int) = x < width / 2 ? (215, 165, 140) : (50, 80, 200)
                bytes[i] = UInt8(clamping: base.0 + delta)
                bytes[i + 1] = UInt8(clamping: base.1 + delta)
                bytes[i + 2] = UInt8(clamping: base.2 + delta)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func variance(_ image: CIImage, _ rect: CGRect) throws -> Double {
        let width = Int(rect.width), height = Int(rect.height)
        var rgba = [Float](repeating: 0, count: width * height * 4)
        ImageRenderer.shared.context.render(image, toBitmap: &rgba, rowBytes: width * 16, bounds: rect, format: .RGBAf, colorSpace: nil)
        let greens = (0..<(width * height)).map { Double(rgba[$0 * 4 + 1]) }
        let mean = greens.reduce(0, +) / Double(greens.count)
        return greens.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(greens.count)
    }
}
