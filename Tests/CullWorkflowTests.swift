import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import PhotographersPocketKnife

final class CullWorkflowTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-cull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testIngestTemplateBuildsFolderStructure() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 13))!
        XCTAssertEqual(IngestTemplate.path("{year}/{date}_{event}/{type}", date: date, event: "Estoril Benfica", isRaw: true), "2026/2026-09-13_Estoril-Benfica/RAW")
        XCTAssertEqual(IngestTemplate.path("{year}/{date}_{event}/{type}", date: date, event: "", isRaw: false), "2026/2026-09-13/JPEG")
        XCTAssertEqual(IngestTemplate.path("{date}", date: date, event: "x", isRaw: false), PhotoImporter.dayString(date))
    }

    func testIngestCopiesToBackupWithVerifiedChecksumsAndReadsSidecars() throws {
        let card = folder.appendingPathComponent("card")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let photo = card.appendingPathComponent("DSC_0001.jpg")
        try writeJPEG(to: photo)
        try PPKSidecar(file: "DSC_0001.jpg", rating: 4, label: "green", flag: 1, develop: nil).write(for: photo)

        let options = PhotoImporter.Options(
            copyDestination: folder.appendingPathComponent("main"),
            subfolderByDate: true,
            folderTemplate: "{event}/{type}",
            event: "Final",
            backupDestination: folder.appendingPathComponent("backup"),
            verifyChecksum: true
        )
        let result = try PhotoImporter.runReporting(files: [photo], options: options) { _, _ in }

        XCTAssertTrue(result.failures.isEmpty)
        let main = folder.appendingPathComponent("main/Final/JPEG/DSC_0001.jpg")
        let backup = folder.appendingPathComponent("backup/Final/JPEG/DSC_0001.jpg")
        XCTAssertEqual(result.infos.first?.url.standardizedFileURL, main.standardizedFileURL)
        XCTAssertEqual(try FileChecksum.sha256(of: main), try FileChecksum.sha256(of: photo))
        XCTAssertEqual(try FileChecksum.sha256(of: backup), try FileChecksum.sha256(of: photo))
        XCTAssertEqual(result.infos.first?.sidecar?.rating, 4, "The .ppk sidecar travels with the copy")
    }

    @MainActor
    func testCatalogAppliesSidecarAndExportsItBack() throws {
        let container = try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var recipe = EditRecipe()
        recipe.exposure = 0.8
        var info = ImportedPhotoInfo(url: URL(fileURLWithPath: "/tmp/A.NEF"), captureDate: nil, camera: nil, lens: nil, width: 10, height: 10, fileSize: 1)
        info.sidecar = PPKSidecar(file: "A.NEF", rating: 5, label: "red", flag: -1, develop: recipe)
        CatalogService.insert([info], session: "S", into: container.mainContext)

        let photo = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<Photo>()).first)
        XCTAssertEqual(photo.rating, 5)
        XCTAssertEqual(photo.flag, .reject)
        XCTAssertEqual(photo.colorLabel, .red)
        XCTAssertEqual(CatalogService.sidecars(for: [photo]).first?.sidecar.develop?.exposure, 0.8)
    }

    func testCaptionTemplateResolvesPerPhoto() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let context = CaptionTemplate.Context(date: date, event: "Taça de Portugal", camera: "Nikon Z9", city: "Oeiras", creator: "David", fileName: "DSC_1.NEF", sequence: 7)
        let caption = CaptionTemplate.resolve("{event}, {city} — {camera} #{seq} ({filename}) {country}", context)
        XCTAssertEqual(caption, "Taça de Portugal, Oeiras — Nikon Z9 #7 (DSC_1.NEF)")
        XCTAssertEqual(CaptionTemplate.resolve("Sem variáveis", context), "Sem variáveis")
    }

    func testXMPRatingAndLabelForLightroom() throws {
        let jpeg = folder.appendingPathComponent("photo.jpg")
        try writeJPEG(to: jpeg)
        try MetadataWriter.writeRating(3, label: .blue, to: jpeg)
        let embedded = try XCTUnwrap(MetadataWriter.readMetadata(for: jpeg))
        XCTAssertEqual(MetadataReader.xmpString(embedded, "xmp:Rating"), "3")
        XCTAssertEqual(MetadataReader.xmpString(embedded, "xmp:Label"), "Blue")

        let raw = folder.appendingPathComponent("IMG_1.CR3")
        try Data("raw".utf8).write(to: raw)
        try MetadataWriter.writeRating(5, label: .none, to: raw)
        let sidecar = try XCTUnwrap(MetadataWriter.readMetadata(for: raw))
        XCTAssertEqual(MetadataReader.xmpString(sidecar, "xmp:Rating"), "5")
        XCTAssertNil(MetadataReader.xmpString(sidecar, "xmp:Label"))
    }

    @MainActor
    func testThumbnailStepsZoomModesAndISOFilter() {
        let model = CullingModel()
        let start = model.thumbnailStep
        model.perform(.larger, in: [])
        XCTAssertEqual(model.thumbnailStep, start + 1)
        for _ in 0..<10 { model.perform(.smaller, in: []) }
        XCTAssertEqual(model.thumbnailSize, CullingModel.thumbnailSizes.first)

        model.perform(.zoom, in: [])
        XCTAssertEqual(model.viewMode, .loupe)
        XCTAssertTrue(model.zoomed)
        model.perform(.magnifier, in: [])
        XCTAssertTrue(model.magnifier)
        XCTAssertFalse(model.zoomed, "Zoom and magnifier are exclusive")
        model.viewMode = .grid
        XCTAssertFalse(model.magnifier, "Leaving the loupe resets zoom modes")

        model.minISO = 3200
        XCTAssertTrue(model.hasActiveFilters)
    }

    @MainActor
    func testDefaultShortcutsAreUnique() {
        let keys = CullingAction.allCases.map(\.defaultKey)
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    private func writeJPEG(to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
