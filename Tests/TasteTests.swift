import XCTest
import SwiftData
import CoreImage
@testable import PhotographersPocketKnife

final class TasteTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Gosto de seleção

    func testTasteProfilePicksWhatThisPhotographerKeeps() throws {
        // Este fotógrafo fica com as fotos luminosas e rejeita as escuras, mesmo que sejam um pouco mais nítidas.
        var examples: [TasteExample] = []
        for index in 0..<20 {
            let keeper = candidate("keep\(index)", seconds: Double(index) * 60, PhotoAssessment(sharpness: 420 + Double(index % 5) * 30, brightness: 0.58 + Double(index % 4) * 0.03))
            let reject = candidate("reject\(index)", seconds: Double(index) * 60 + 3000, PhotoAssessment(sharpness: 470 + Double(index % 5) * 30, brightness: 0.26 + Double(index % 4) * 0.03))
            examples += [TasteExample(candidate: keeper, keeper: true), TasteExample(candidate: reject, keeper: false)]
        }
        let trainingReport = SmartCull.evaluate(examples.map(\.candidate), options: CullOptions()) { _, _ in nil }
        let profile = try XCTUnwrap(TasteLearner.train(name: "Luz", examples: examples, report: trainingReport))
        XCTAssertEqual(profile.keepers, 20)
        XCTAssertEqual(profile.rejects, 20)

        let dark = candidate("dark", seconds: 0, PhotoAssessment(sharpness: 650, brightness: 0.3))
        let bright = candidate("bright", seconds: 2, PhotoAssessment(sharpness: 500, brightness: 0.62))
        let generic = SmartCull.evaluate([dark, bright], options: CullOptions()) { _, _ in nil }
        XCTAssertEqual(generic.best, [dark.id], "Technical criteria alone prefer the sharper shot")

        let personal = SmartCull.evaluate([dark, bright], options: CullOptions(), distance: { _, _ in nil }, taste: profile)
        XCTAssertEqual(personal.best, [bright.id], "With the profile, the photographer's taste wins")
        XCTAssertGreaterThan(personal.taste[bright.id] ?? 0, personal.taste[dark.id] ?? 1)

        let decisions = SmartCull.decisions(for: [dark, bright], report: personal, options: CullOptions())
        XCTAssertEqual(decisions[bright.id]?.flag, .pick)
        XCTAssertEqual(decisions[dark.id]?.flag, .reject, "A shot this photographer would not keep is rejected")
    }

    func testTooFewChoicesDoNotMakeAProfile() {
        let examples = (0..<3).map { TasteExample(candidate: candidate("k\($0)", seconds: Double($0)), keeper: true) }
            + (0..<30).map { TasteExample(candidate: candidate("r\($0)", seconds: Double($0) + 100), keeper: false) }
        XCTAssertNil(TasteLearner.train(name: "x", examples: examples, report: CullReport()))
    }

    func testDeliveredFilesMatchTheirOriginals() {
        XCTAssertTrue(TasteLearner.isMatch(original: "DSC_1234.NEF", deliveredBase: "DSC_1234"))
        XCTAssertTrue(TasteLearner.isMatch(original: "DSC_1234.NEF", deliveredBase: "dsc_1234-Edit"))
        XCTAssertTrue(TasteLearner.isMatch(original: "IMG_0042.CR3", deliveredBase: "IMG_0042 (2)"))
        XCTAssertFalse(TasteLearner.isMatch(original: "DSC_1234.NEF", deliveredBase: "DSC_12345"))
        XCTAssertFalse(TasteLearner.isMatch(original: "DSC_1234.NEF", deliveredBase: "DSC_123"))
    }

    @MainActor
    func testExamplesComeFromCatalogChoicesAndDeliveredFolders() throws {
        let container = try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        func photo(_ name: String, session: String, rating: Int = 0, flag: PhotoFlag = .none) -> Photo {
            let info = ImportedPhotoInfo(url: URL(fileURLWithPath: "/tmp/\(name)"), captureDate: nil, camera: nil, lens: nil, width: 1, height: 1, fileSize: 1)
            let photo = Photo(info: info, sessionName: session)
            photo.rating = rating
            photo.flag = flag
            container.mainContext.insert(photo)
            return photo
        }
        let picked = photo("A.NEF", session: "Jogo", flag: .pick)
        let starred = photo("B.NEF", session: "Jogo", rating: 4)
        let rejected = photo("C.NEF", session: "Jogo", rating: 4, flag: .reject)
        let oneStar = photo("D.NEF", session: "Jogo", rating: 1)
        let untouched = photo("E.NEF", session: "Jogo")
        let otherShoot = photo("F.NEF", session: "Casamento")
        let all = [picked, starred, rejected, oneStar, untouched, otherShoot]

        let decided = CullingModel.decisionExamples(all)
        XCTAssertEqual(Set(decided.keepers.map(\.fileName)), ["A.NEF", "B.NEF"])
        XCTAssertEqual(Set(decided.rejects.map(\.fileName)), ["C.NEF", "D.NEF"])

        let delivered = [URL(fileURLWithPath: "/entregues/A-Edit.jpg"), URL(fileURLWithPath: "/entregues/E.jpg")]
        let folder = CullingModel.folderExamples(all, delivered: delivered)
        XCTAssertEqual(Set(folder.keepers.map(\.fileName)), ["A.NEF", "E.NEF"])
        XCTAssertEqual(Set(folder.rejects.map(\.fileName)), ["B.NEF", "C.NEF", "D.NEF"], "Only the same shoot counts as not delivered")
    }

    func testTasteProfilesAreStored() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-taste-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TasteProfileStore(directory: folder)
        let profile = TasteProfile(name: "Desporto", weights: Array(repeating: 0.1, count: 13), means: Array(repeating: 0, count: 12),
                                   scales: Array(repeating: 1, count: 12), keeperPrints: [], rejectPrints: [], keepers: 10, rejects: 12)
        store.save(profile)
        XCTAssertEqual(store.profile(id: profile.id)?.name, "Desporto")
        XCTAssertEqual(store.all().count, 1)
        store.delete(profile.id)
        XCTAssertNil(store.profile(id: profile.id))
    }

    // MARK: Estilo a partir de fotos entregues e do Lightroom

    func testStyleFitterRecoversTheDeliveredLook() throws {
        let original = CIImage(cgImage: try scene())
        var look = EditRecipe()
        look.exposure = 0.7
        look.saturation = 0.3
        look.contrast = 0.2
        let delivered = ImageRenderer.shared.apply(look, to: original, applyCrop: false)
        let final = CIImage(cgImage: try XCTUnwrap(ImageRenderer.shared.context.createCGImage(delivered, from: original.extent, format: .RGBA8, colorSpace: ImageRenderer.shared.sRGB)))

        let fitted = try XCTUnwrap(StyleFitter.fit(original: original, final: final))
        XCTAssertEqual(fitted.exposure, 0.7, accuracy: 0.35)
        let before = try meanDifference(original, final)
        let after = try meanDifference(ImageRenderer.shared.apply(fitted, to: original, applyCrop: false), final)
        XCTAssertLessThan(after, before * 0.3, "The fitted edit gets close to the delivered photo")

        let cropped = final.cropped(to: CGRect(x: 0, y: 0, width: 200, height: 320))
        XCTAssertNil(StyleFitter.fit(original: original, final: cropped), "A different crop cannot be compared pixel by pixel")
    }

    func testLightroomDevelopSettingsAreReadFromRawSidecars() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let developed = folder.appendingPathComponent("DSC_0001.NEF")
        try Data("raw".utf8).write(to: developed)
        let xmp = #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+0.80" crs:Vibrance="+25"/></rdf:RDF></x:xmpmeta>"#
        try Data(xmp.utf8).write(to: MetadataWriter.sidecarURL(for: developed))
        let recipe = try XCTUnwrap(LightroomPreset.sidecarRecipe(for: developed))
        XCTAssertEqual(recipe.exposure, 0.8, accuracy: 1e-9)
        XCTAssertEqual(recipe.vibrance, 0.25, accuracy: 1e-9)

        let ratedOnly = folder.appendingPathComponent("DSC_0002.NEF")
        try Data("raw".utf8).write(to: ratedOnly)
        try MetadataWriter.writeRating(4, label: .green, to: ratedOnly)
        XCTAssertNil(LightroomPreset.sidecarRecipe(for: ratedOnly), "A sidecar with only stars has no develop settings")
    }

    // MARK: Utilitários

    private func candidate(_ name: String, seconds: Double, _ assessment: PhotoAssessment = PhotoAssessment(sharpness: 400)) -> CullCandidate {
        CullCandidate(id: UUID(), date: start.addingTimeInterval(seconds), fileName: name, rating: 0, flag: .none, assessment: assessment)
    }

    private func scene() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 480, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 160, width: 480, height: 160))
        context.setFillColor(CGColor(red: 0.35, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 160))
        for index in 0..<6 {
            context.setFillColor(CGColor(red: 0.6, green: 0.35 + CGFloat(index) * 0.04, blue: 0.25, alpha: 1))
            context.fillEllipse(in: CGRect(x: 30 + index * 75, y: 60 + (index % 2) * 40, width: 50, height: 50))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func meanDifference(_ a: CIImage, _ b: CIImage) throws -> Double {
        let e = b.extent
        let width = Int(e.width), height = Int(e.height)
        func pixels(_ image: CIImage) -> [Float] {
            var rgba = [Float](repeating: 0, count: width * height * 4)
            ImageRenderer.shared.context.render(image, toBitmap: &rgba, rowBytes: width * 16, bounds: e, format: .RGBAf, colorSpace: ImageRenderer.shared.sRGB)
            return rgba.map { min(max($0, 0), 1) }
        }
        let pa = pixels(a), pb = pixels(b)
        var total = 0.0
        for i in 0..<pa.count where i % 4 != 3 { total += Double(abs(pa[i] - pb[i])) }
        return total / Double(width * height * 3)
    }
}
