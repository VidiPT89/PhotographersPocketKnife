import XCTest
import SwiftData
@testable import PhotographersPocketKnife

/// Catálogo e `.ppk` gravados pela 1.0.2 (Tests/Fixtures), abertos com o código atual.
final class CatalogUpgradeTests: XCTestCase {
    private var folder: URL!
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Cópia do catálogo antigo: abrir com o esquema novo altera o ficheiro.
    private func legacyCatalog(named name: String = "Catalog.store") throws -> URL {
        let source = fixtures.appendingPathComponent("Catalog-1.0.2.store")
        guard FileManager.default.isReadableFile(atPath: source.path) else { throw XCTSkip("Fixtures not readable from this test host") }
        let copy = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func open(_ url: URL) throws -> ModelContainer {
        try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self,
                           configurations: ModelConfiguration(url: url))
    }

    @MainActor
    func testCatalogFromVersion102OpensWithEverythingKept() throws {
        let container = try open(try legacyCatalog())
        let context = container.mainContext

        let photos = try context.fetch(FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.fileName)]))
        XCTAssertEqual(photos.map(\.fileName), ["DSC_0001.NEF", "DSC_0002.JPG"])
        let shot = photos[0]
        XCTAssertEqual(shot.rating, 4)
        XCTAssertEqual(shot.flag, .pick)
        XCTAssertEqual(shot.colorLabel, .green)
        XCTAssertEqual(shot.camera, "NIKON Z 9")
        XCTAssertEqual(shot.iso, 3200)
        XCTAssertEqual(shot.latitude, 38.7)
        XCTAssertEqual(shot.keywords, "tennis, final")
        XCTAssertEqual(shot.deliveredTo, "Agency FTP")
        XCTAssertEqual(shot.sessionName, "Estoril Open")
        XCTAssertNil(shot.sourcePath, "Field added after 1.0.2 starts empty")
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(shot.recipeData))
        XCTAssertEqual(recipe.exposure, 0.7)
        XCTAssertEqual(recipe.contrast, 12)
        XCTAssertEqual(photos[1].flag, .reject)

        let destination = try XCTUnwrap(context.fetch(FetchDescriptor<UploadDestination>()).first)
        XCTAssertEqual(destination.transferProtocol, .ftps)
        XCTAssertEqual(destination.host, "ftp.example.com")
        XCTAssertEqual(destination.port, 2121)
        XCTAssertEqual(destination.username, "photographer")
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<UploadRecord>()).first)
        XCTAssertEqual(record.destinationID, destination.id)
        XCTAssertEqual(record.bytes, 4_200_000)
        let preset = try XCTUnwrap(context.fetch(FetchDescriptor<EditPreset>()).first)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: preset.recipeData).exposure, 0.7)
    }

    @MainActor
    func testUpgradedCatalogTakesNewFieldsAndReopens() throws {
        let url = try legacyCatalog()
        do {
            let container = try open(url)
            let context = container.mainContext
            let shot = try XCTUnwrap(context.fetch(FetchDescriptor<Photo>(predicate: #Predicate { $0.fileName == "DSC_0002.JPG" })).first)
            shot.sourcePath = "/Volumes/Card/DCIM/DSC_0002.JPG"
            shot.rating = 5
            try context.save()
        }
        // O contexto não segura o contentor: sem esta referência, o SwiftData vai abaixo a meio da leitura.
        let container = try open(url)
        let reopened = container.mainContext
        let shot = try XCTUnwrap(reopened.fetch(FetchDescriptor<Photo>(predicate: #Predicate { $0.fileName == "DSC_0002.JPG" })).first)
        XCTAssertEqual(shot.sourcePath, "/Volumes/Card/DCIM/DSC_0002.JPG")
        XCTAssertEqual(shot.rating, 5)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Photo>()), 2)
    }

    @MainActor
    func testOldDefaultStoreFromVersion102IsMovedAndOpened() throws {
        let legacy = try legacyCatalog(named: "default.store")
        let target = folder.appendingPathComponent("PhotographersPocketKnife/Catalog.store")
        XCTAssertTrue(CatalogStore.isCatalog(legacy))
        XCTAssertTrue(try CatalogStore.migrateLegacy(from: legacy, to: target))
        let container = try open(target)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Photo>()), 2)
    }

    func testSidecarFromVersion102IsRead() throws {
        let photo = fixtures.appendingPathComponent("DSC_0001.NEF")
        guard FileManager.default.isReadableFile(atPath: PPKSidecar.url(for: photo).path) else { throw XCTSkip("Fixtures not readable from this test host") }
        let sidecar = try XCTUnwrap(PPKSidecar.read(for: photo))
        XCTAssertEqual(sidecar.rating, 4)
        XCTAssertEqual(sidecar.label, "green")
        XCTAssertEqual(sidecar.flag, 1)
        XCTAssertEqual(sidecar.develop?.exposure, 0.7)
    }
}
