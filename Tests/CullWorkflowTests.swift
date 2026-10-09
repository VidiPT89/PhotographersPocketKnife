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

        try MetadataWriter.writeRating(2, label: .none, to: jpeg)
        let cleared = try XCTUnwrap(MetadataWriter.readMetadata(for: jpeg))
        XCTAssertNil(MetadataReader.xmpString(cleared, "xmp:Label"))
        XCTAssertEqual(MetadataReader.xmpString(cleared, "xmp:Rating"), "2")

        let raw = folder.appendingPathComponent("IMG_1.CR3")
        try Data("raw".utf8).write(to: raw)
        try MetadataWriter.writeRating(4, label: .green, to: raw)
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

    func testRAWJPEGPairsMatchByFolderAndNameIgnoringCase() {
        let raw = UUID(), jpeg = UUID(), elsewhere = UUID(), heic = UUID(), lone = UUID()
        let twins = PhotoPairs.twins([
            (raw, "/card/DCIM/IMG_0001.CR3"),
            (jpeg, "/card/DCIM/img_0001.JPG"),
            (heic, "/card/DCIM/IMG_0001.heic"),
            (elsewhere, "/backup/IMG_0001.JPG"),
            (lone, "/card/DCIM/IMG_0002.JPG"),
        ])
        XCTAssertEqual(twins.count, 1)
        XCTAssertEqual(Set(twins[raw] ?? []), [jpeg, heic])
    }

    @MainActor
    func testStackedPairsHideTheJPEGAndShareClassification() throws {
        let container = try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let raw = photo("/shoot/A.NEF"), jpeg = photo("/shoot/A.JPG"), other = photo("/shoot/B.JPG")
        [raw, jpeg, other].forEach(container.mainContext.insert)
        let catalog = [raw, jpeg, other]
        let model = CullingModel()
        let saved = UserDefaults.standard.object(forKey: "culling.stackPairs")
        defer { UserDefaults.standard.set(saved, forKey: "culling.stackPairs") }

        model.stackPairs = false
        XCTAssertEqual(model.visible(catalog).count, 3)
        model.selection = [raw.id]
        model.perform(.rate4, in: model.visible(catalog), catalog: catalog)
        XCTAssertEqual(jpeg.rating, 0, "Without stacking, the JPEG is its own photo")

        model.stackPairs = true
        let list = model.visible(catalog)
        XCTAssertEqual(Set(list.map(\.id)), [raw.id, other.id])
        model.perform(.rate5, in: list, catalog: catalog)
        model.perform(.pick, in: list, catalog: catalog)
        model.perform(.labelGreen, in: list, catalog: catalog)
        XCTAssertEqual(jpeg.rating, 5)
        XCTAssertEqual(jpeg.flag, .pick)
        XCTAssertEqual(jpeg.colorLabel, .green)
        XCTAssertEqual(other.rating, 0)
        model.perform(.pick, in: list, catalog: catalog)
        XCTAssertEqual(jpeg.flag, .none, "Toggling off clears both files")
    }

    @MainActor
    func testDeliveryFilterSeparatesSentFromPending() {
        let sent = photo("/shoot/sent.jpg"), pending = photo("/shoot/pending.jpg")
        sent.deliveredAt = Date()
        let model = CullingModel()
        model.deliveryFilter = .delivered
        XCTAssertTrue(model.hasActiveFilters)
        XCTAssertEqual(model.visible([sent, pending]).map(\.id), [sent.id])
        model.deliveryFilter = .pending
        XCTAssertEqual(model.visible([sent, pending]).map(\.id), [pending.id])
        model.clearFilters()
        XCTAssertEqual(model.deliveryFilter, .all)
    }

    @MainActor
    func testRelinkMovesOnlyPhotosFoundUnderTheNewFolder() throws {
        let container = try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let nested = photo("/Volumes/Old/2026/a.jpg"), top = photo("/Volumes/Old/b.jpg")
        let gone = photo("/Volumes/Old/c.jpg"), unrelated = photo("/Volumes/Older/d.jpg")
        [nested, top, gone, unrelated].forEach(container.mainContext.insert)
        let present: Set<String> = ["/Volumes/New/2026/a.jpg", "/Volumes/New/b.jpg", "/Volumes/New/d.jpg"]

        let found = CatalogService.relink(from: URL(fileURLWithPath: "/Volumes/Old"), to: URL(fileURLWithPath: "/Volumes/New/"),
                                          in: container.mainContext, fileExists: present.contains)
        XCTAssertEqual(found, 2)
        XCTAssertEqual(nested.path, "/Volumes/New/2026/a.jpg")
        XCTAssertEqual(top.path, "/Volumes/New/b.jpg")
        XCTAssertEqual(gone.path, "/Volumes/Old/c.jpg", "A file missing from the new folder keeps its old path")
        XCTAssertEqual(unrelated.path, "/Volumes/Older/d.jpg", "A sibling folder sharing the prefix is not touched")
    }

    @MainActor
    func testLegacyCatalogIsCopiedOnceIntoTheAppFolder() throws {
        let legacy = folder.appendingPathComponent("default.store")
        let target = folder.appendingPathComponent("PhotographersPocketKnife/Catalog.store")
        do {
            let container = try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self,
                                               configurations: ModelConfiguration(url: legacy))
            let kept = photo("/shoot/kept.jpg")
            kept.rating = 4
            container.mainContext.insert(kept)
            try container.mainContext.save()
        }
        XCTAssertTrue(CatalogStore.isCatalog(legacy))
        XCTAssertTrue(try CatalogStore.migrateLegacy(from: legacy, to: target))
        XCTAssertFalse(try CatalogStore.migrateLegacy(from: legacy, to: target), "Never overwrite the new catalog")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "The old catalog is left in place")

        let reopened = try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self,
                                          configurations: ModelConfiguration(url: target))
        let photos = try reopened.mainContext.fetch(FetchDescriptor<Photo>())
        XCTAssertEqual(photos.map(\.rating), [4])
    }

    func testForeignDatabaseIsNotTakenAsTheCatalog() throws {
        let foreign = folder.appendingPathComponent("default.store")
        try Data("not a database".utf8).write(to: foreign)
        let target = folder.appendingPathComponent("new/Catalog.store")
        XCTAssertFalse(CatalogStore.isCatalog(foreign))
        XCTAssertFalse(try CatalogStore.migrateLegacy(from: foreign, to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    @MainActor
    func testSidecarIsWrittenOnItsOwnWhenTheCatalogSaves() async throws {
        let container = try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let url = folder.appendingPathComponent("DSC_1.jpg")
        try writeJPEG(to: url)
        let shot = photo(url.path)
        context.insert(shot)
        try context.save()

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PPKSidecarAutosave-\(UUID().uuidString)"))
        let autosave = SidecarAutosave(defaults: defaults)
        XCTAssertTrue(autosave.isEnabled, "On by default, like Photo Mechanic")
        autosave.delay = .milliseconds(10)
        autosave.attach(context: context)

        shot.rating = 4
        shot.colorLabel = .green
        try context.save()
        for _ in 0..<100 where PPKSidecar.read(for: url) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let saved = try XCTUnwrap(PPKSidecar.read(for: url))
        XCTAssertEqual(saved.rating, 4)
        XCTAssertEqual(saved.label, "green")

        autosave.isEnabled = false
        shot.rating = 1
        try context.save()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(PPKSidecar.read(for: url)?.rating, 4, "Switched off, the files are left alone")
    }

    @MainActor
    private func photo(_ path: String) -> Photo {
        Photo(info: ImportedPhotoInfo(url: URL(fileURLWithPath: path), captureDate: nil, camera: nil, lens: nil, width: 1, height: 1, fileSize: 1), sessionName: "S")
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
