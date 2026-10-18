import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import SwiftData
@testable import PhotographersPocketKnife

final class MobileTests: XCTestCase {
    func testRecipeRoundTripIncludesMasksAndRemoval() throws {
        var recipe = EditRecipe()
        recipe.exposure = 1.25
        recipe.masks = [LocalMask(kind: .radial)]
        recipe.removals = [Removal(strokes: [BrushStroke(points: [.init(x: 0.3, y: 0.4)])])]
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe)), recipe)
    }
    func testImportCopiesOriginalAndPreservesSidecar() throws {
        let root = try fixtureDirectory()
        let source = try fixture(in: root)
        let checksum = try FileChecksum.sha256(of: source)
        try PPKSidecar(file: source.lastPathComponent, rating: 4, label: "green", flag: 1, develop: nil).write(for: source)
        let target = root.appendingPathComponent("Imported")
        var options = PhotoImporter.Options(copyDestination: target)
        options.verifyChecksum = true
        let result = try PhotoImporter.runReporting(files: [source], options: options) { _, _ in }
        XCTAssertTrue(result.failures.isEmpty)
        let copied = try XCTUnwrap(result.infos.first?.url)
        XCTAssertNotEqual(copied, source)
        XCTAssertEqual(try FileChecksum.sha256(of: copied), checksum)
        XCTAssertEqual(try FileChecksum.sha256(of: source), checksum)
        XCTAssertEqual(PPKSidecar.read(for: copied)?.rating, 4)
    }
    func testExportAllFormatsPreservesOriginal() throws {
        let root = try fixtureDirectory(), source = try fixture(in: root)
        let checksum = try FileChecksum.sha256(of: source)
        var recipe = EditRecipe(); recipe.exposure = 0.6
        for format in ExportFormat.allCases {
            var settings = ExportSettings(); settings.format = format
            settings.resize = true; settings.longEdge = 160
            settings.watermarkEnabled = true; settings.watermarkText = "© Pocket Knife"
            let exported = try ImageRenderer.shared.export(url: source, recipe: recipe, settings: settings, to: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
            if format != .dng {
                let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(exported as CFURL, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
                XCTAssertEqual(max(image.width, image.height), 160)
            }
        }
        XCTAssertEqual(try FileChecksum.sha256(of: source), checksum)
    }
    func testMetadataRoundTrip() throws {
        let root = try fixtureDirectory(), source = try fixture(in: root)
        var fields = IPTCFields(); fields.caption = "Lisboa, fotógrafo"; fields.creator = "David"; fields.keywords = "sport, portrait"
        try MetadataWriter.write(fields, to: source)
        let result = MetadataReader.iptcFields(for: source)
        XCTAssertEqual(result.caption, fields.caption)
        XCTAssertEqual(result.creator, "David")
    }
    func testCancelledNativeTransferDoesNotConnect() async throws {
        let process = CurlProcess(); process.cancel()
        let endpoint = TransferEndpoint(transferProtocol: .ftp, host: "127.0.0.1", port: 1, username: "", password: "", bucket: "", region: "", trustUnknownHostKey: false)
        do { try await process.execute(.test(endpoint)); XCTFail("Cancelled transfer connected") }
        catch { XCTAssertEqual(error as? TransferError, .cancelled) }
    }
    @MainActor func testEditsAndRatingsSurviveCatalogReopen() throws {
        let root = try fixtureDirectory(), source = try fixture(in: root)
        let schema = Schema([Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self])
        let config = ModelConfiguration(schema: schema, url: root.appendingPathComponent("Catalog.store"))
        do {
            let container = try ModelContainer(for: schema, configurations: config)
            let context = ModelContext(container)
            let photo = Photo(info: MetadataReader.basicInfo(for: source), sessionName: "Test")
            photo.rating = 5; photo.flag = .pick
            var recipe = EditRecipe(); recipe.exposure = 0.75
            photo.recipeData = try JSONEncoder().encode(recipe)
            context.insert(photo); try context.save()
        }
        let reopened = try ModelContainer(for: schema, configurations: config)
        let photos = try ModelContext(reopened).fetch(FetchDescriptor<Photo>())
        let photo = try XCTUnwrap(photos.first)
        XCTAssertEqual(photo.rating, 5); XCTAssertEqual(photo.flag, .pick)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(photo.recipeData)).exposure, 0.75)
    }
    /// Catálogo de 30 mil fotos no disco: o arranque lê tudo por data de importação, como a grelha.
    @MainActor func testLargeCatalogOnDiskStaysFast() throws {
        let root = try fixtureDirectory()
        let schema = Schema([Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self])
        let config = ModelConfiguration(schema: schema, url: root.appendingPathComponent("Catalog.store"))
        let count = 30_000
        var start = Date()
        do {
            let container = try ModelContainer(for: schema, configurations: config)
            let infos = (0..<count).map { i in
                ImportedPhotoInfo(url: URL(fileURLWithPath: "/big/DSC_\(i).NEF"), captureDate: Date(timeIntervalSince1970: Double(i)),
                                  camera: i % 3 == 0 ? "NIKON Z 9" : "Sony A1", lens: "70-200", width: 8256, height: 5504, fileSize: 60_000_000)
            }
            XCTAssertEqual(try CatalogService.insert(infos, session: "Season", into: container.mainContext), count)
        }
        let insertTime = Date().timeIntervalSince(start)

        start = Date()
        let container = try ModelContainer(for: schema, configurations: config)
        let all = try container.mainContext.fetch(FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.importedAt, order: .reverse)]))
        let openTime = Date().timeIntervalSince(start)
        XCTAssertEqual(all.count, count)

        for (index, photo) in all.enumerated() where index % 5 == 0 { photo.rating = 4; photo.keywords = "final" }
        start = Date()
        try container.mainContext.save()
        let saveTime = Date().timeIntervalSince(start)

        let model = CullingModel()
        model.minRating = 3
        model.camera = "NIKON Z 9"
        model.searchText = "final"
        start = Date()
        let visible = model.visible(all)
        let filterTime = Date().timeIntervalSince(start)
        XCTAssertEqual(visible.count, all.filter { $0.rating >= 3 && $0.camera == "NIKON Z 9" }.count)
        XCTAssertGreaterThan(visible.count, 0)

        print("PPK iOS perf 30k — insert: \(insertTime)s, reopen+fetch: \(openTime)s, save 6k edits: \(saveTime)s, filter+search+sort: \(filterTime)s")
        XCTAssertLessThan(openTime, 5)
        XCTAssertLessThan(saveTime, 5)
        XCTAssertLessThan(filterTime, 1.5)
    }
    private func fixtureDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PPK-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func fixture(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("photo.jpg")
        let image = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.7)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240))
        let cg = try XCTUnwrap(ImageRenderer.shared.context.createCGImage(image, from: image.extent))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return url
    }
}
