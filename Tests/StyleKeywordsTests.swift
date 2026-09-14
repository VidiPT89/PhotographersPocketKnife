import XCTest
import SwiftData
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotographersPocketKnife

final class StyleKeywordsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-style-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Lightroom

    func testLightroomPresetIsMappedToTheSliders() throws {
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:Exposure2012="+0.50" crs:Contrast2012="+20" crs:Highlights2012="-40" crs:Vibrance="+15"
          crs:SaturationAdjustmentBlue="-30" crs:PostCropVignetteAmount="-25" crs:GrainAmount="10"
          crs:SplitToningShadowHue="220" crs:SplitToningShadowSaturation="12" crs:LensProfileEnable="1">
          <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">Film Warm</rdf:li></rdf:Alt></crs:Name>
          <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 10</rdf:li><rdf:li>128, 140</rdf:li><rdf:li>255, 245</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let preset = try XCTUnwrap(LightroomPreset.parse(Data(xmp.utf8)))
        XCTAssertEqual(preset.name, "Film Warm")
        let r = preset.recipe
        XCTAssertEqual(r.exposure, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.contrast, 0.2, accuracy: 1e-9)
        XCTAssertEqual(r.highlights, -0.4, accuracy: 1e-9)
        XCTAssertEqual(r.vibrance, 0.15, accuracy: 1e-9)
        XCTAssertEqual(r.hsl[HSLBand.blue.rawValue].saturation, -0.3, accuracy: 1e-9)
        XCTAssertEqual(r.vignette, -0.25, accuracy: 1e-9)
        XCTAssertEqual(r.grain, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r.shadowsHue, 220, accuracy: 1e-9)
        XCTAssertEqual(r.shadowsSaturation, 0.12, accuracy: 1e-9)
        XCTAssertTrue(r.lensCorrection)
        XCTAssertEqual(r.curveMaster.count, 3)
        XCTAssertEqual(r.curveMaster[0].y, 10.0 / 255, accuracy: 1e-9)

        XCTAssertNil(LightroomPreset.parse(Data("not xml at all".utf8)))
        XCTAssertNil(LightroomPreset.parse(Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"/>"#.utf8)))
    }

    // MARK: Estilo pessoal

    func testPersonalStyleLearnsTheLookAndAdaptsExposureToEachPhoto() throws {
        var look = EditRecipe()
        look.vibrance = 0.4
        look.grain = 0.2
        look.hsl[HSLBand.orange.rawValue].saturation = -0.25
        look.setCurve([CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 0.95)], for: .master)

        let examples = try [0.25, 0.35, 0.5, 0.6].map { brightness -> StyleExample in
            let image = CIImage(cgImage: try scene(brightness: brightness))
            var recipe = look
            recipe.exposure = AutoEnhance.enhance(EditRecipe(), image: image).exposure + 0.6
            recipe.crop = CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            return PersonalStyle.example(image: image, recipe: recipe)
        }
        XCTAssertEqual(examples[0].look.crop, CropRect(), "Framing is not part of the look")

        let profile = StyleProfile(name: "Casamentos", examples: examples)
        let newPhoto = CIImage(cgImage: try scene(brightness: 0.42))
        var current = EditRecipe()
        current.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        let styled = PersonalStyle.predict(profile, for: newPhoto, current: current)

        XCTAssertEqual(styled.vibrance, 0.4, accuracy: 1e-6)
        XCTAssertEqual(styled.grain, 0.2, accuracy: 1e-6)
        XCTAssertEqual(styled.hsl[HSLBand.orange.rawValue].saturation, -0.25, accuracy: 1e-6)
        XCTAssertEqual(styled.curveMaster, look.curveMaster)
        XCTAssertEqual(styled.exposure, AutoEnhance.enhance(EditRecipe(), image: newPhoto).exposure + 0.6, accuracy: 0.01)
        XCTAssertEqual(styled.crop, current.crop, "This photo keeps its own crop")

        let store = StyleProfileStore(directory: folder.appendingPathComponent("Styles"))
        store.save(profile)
        XCTAssertEqual(store.all().map(\.name), ["Casamentos"])
        XCTAssertEqual(store.all().first?.examples.count, 4)
        store.delete(profile.id)
        XCTAssertTrue(store.all().isEmpty)
    }

    // MARK: Palavras-chave

    func testKeywordsAreMergedWithoutDuplicatesAndWrittenToTheFile() throws {
        XCTAssertEqual(AutoKeywords.merged(["Futebol", "estádio"], ["futebol", "sky", "Sky", " "]), ["Futebol", "estádio", "sky"])

        let file = folder.appendingPathComponent("jogo.jpg")
        try writeJPEG(try scene(brightness: 0.5), to: file)
        var fields = IPTCFields()
        fields.keywords = "futebol"
        try MetadataWriter.write(fields, to: file)
        XCTAssertEqual(AutoKeywords.existing(for: file), ["futebol"])

        XCTAssertLessThanOrEqual(AutoKeywords.suggest(for: try scene(brightness: 0.5)).count, 8)
        let written = try AutoKeywords.apply(to: file)
        XCTAssertEqual(written.first, "futebol", "Existing keywords stay first")
        XCTAssertEqual(Set(AutoKeywords.existing(for: file)), Set(written))
    }

    @MainActor
    func testSearchAlsoMatchesKeywords() throws {
        let container = try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let info = ImportedPhotoInfo(url: URL(fileURLWithPath: "/tmp/IMG_1.jpg"), captureDate: nil, camera: nil, lens: nil, width: 1, height: 1, fileSize: 1)
        let photo = Photo(info: info, sessionName: "Praia")
        photo.keywords = "sky, beach"
        container.mainContext.insert(photo)
        let model = CullingModel()
        model.searchText = "beach"
        XCTAssertEqual(model.visible([photo]).count, 1)
        model.searchText = "mountain"
        XCTAssertTrue(model.visible([photo]).isEmpty)
    }

    // MARK: Utilitários

    /// Céu, chão e alguns círculos, com o brilho pedido.
    private func scene(brightness: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 480, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.5 * brightness, green: 0.7 * brightness, blue: 0.95 * brightness, alpha: 1))
        context.fill(CGRect(x: 0, y: 160, width: 480, height: 160))
        context.setFillColor(CGColor(red: 0.45 * brightness, green: 0.4 * brightness, blue: 0.25 * brightness, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 160))
        for index in 0..<6 {
            context.setFillColor(CGColor(red: min(0.9 * brightness + 0.1, 1), green: 0.5 * brightness, blue: 0.3 * brightness, alpha: 1))
            context.fillEllipse(in: CGRect(x: 30 + index * 75, y: 60 + (index % 2) * 40, width: 50, height: 50))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func writeJPEG(_ image: CGImage, to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
