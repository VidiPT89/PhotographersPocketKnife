import XCTest
import SwiftData
@testable import PhotographersPocketKnife

@MainActor
final class CullingModelTests: XCTestCase {
    private var container: ModelContainer!
    private var photos: [Photo] = []

    override func setUp() async throws {
        container = try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let infos = (1...6).map { i in
            ImportedPhotoInfo(url: URL(fileURLWithPath: "/tmp/IMG_\(i).jpg"), captureDate: Date(timeIntervalSince1970: Double(i) * 60),
                              camera: i % 2 == 0 ? "Nikon Z9" : "Sony A1", lens: nil, width: 10, height: 10, fileSize: 1)
        }
        CatalogService.insert(infos, session: "Jogo", into: container.mainContext)
        // Reimportar os mesmos caminhos não duplica.
        let duplicates = CatalogService.insert(infos, session: "Jogo", into: container.mainContext)
        XCTAssertEqual(duplicates, 0)
        photos = try container.mainContext.fetch(FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.captureDate)]))
    }

    func testRatingFlagAndColorActionsApplyToSelection() {
        let model = CullingModel()
        model.selection = [photos[0].id, photos[1].id]
        model.perform(.rate4, in: photos)
        model.perform(.pick, in: photos)
        model.perform(.labelGreen, in: photos)
        XCTAssertEqual(photos[0].rating, 4)
        XCTAssertEqual(photos[1].flag, .pick)
        XCTAssertEqual(photos[1].colorLabel, .green)
        XCTAssertEqual(photos[2].rating, 0)

        model.perform(.pick, in: photos)
        XCTAssertEqual(photos[0].flag, .none, "Pick toggles off")
    }

    func testFiltersAndSorting() {
        let model = CullingModel()
        photos[2].rating = 5
        photos[3].rating = 3
        photos[3].flag = .reject

        model.minRating = 3
        XCTAssertEqual(model.visible(photos).map(\.fileName), ["IMG_3.jpg", "IMG_4.jpg"])
        model.flagFilter = .rejects
        XCTAssertEqual(model.visible(photos).map(\.fileName), ["IMG_4.jpg"])
        model.clearFilters()

        model.camera = "Nikon Z9"
        model.sortAscending = false
        XCTAssertEqual(model.visible(photos).map(\.fileName), ["IMG_6.jpg", "IMG_4.jpg", "IMG_2.jpg"])
    }

    /// Catálogo de 10 mil fotos: inserir, ler e filtrar tem de continuar rápido.
    func testLargeCatalogStaysFast() throws {
        let context = container.mainContext
        let infos = (0..<10_000).map { i in
            ImportedPhotoInfo(url: URL(fileURLWithPath: "/tmp/big/IMG_\(i).CR3"), captureDate: Date(timeIntervalSince1970: Double(i)),
                              camera: i % 3 == 0 ? "Canon R5" : "Nikon Z8", lens: "50mm", width: 8192, height: 5464, fileSize: 45_000_000)
        }
        var start = Date()
        XCTAssertEqual(CatalogService.insert(infos, session: "Grande", into: context), 10_000)
        let insertTime = Date().timeIntervalSince(start)

        start = Date()
        let all = try context.fetch(FetchDescriptor<Photo>())
        let fetchTime = Date().timeIntervalSince(start)
        for (index, photo) in all.enumerated() where index % 7 == 0 { photo.rating = 4 }

        let model = CullingModel()
        model.session = "Grande"
        model.minRating = 3
        model.camera = "Canon R5"
        start = Date()
        let visible = model.visible(all)
        let filterTime = Date().timeIntervalSince(start)

        XCTAssertEqual(visible.count, all.filter { $0.rating >= 3 && $0.camera == "Canon R5" }.count)
        XCTAssertGreaterThan(visible.count, 0)
        print("PPK perf 10k — insert: \(insertTime)s, fetch: \(fetchTime)s, filter+sort: \(filterTime)s")
        XCTAssertLessThan(insertTime, 10)
        XCTAssertLessThan(fetchTime, 3)
        XCTAssertLessThan(filterTime, 0.5)
    }

    func testKeyboardNavigationAndCompare() {
        let model = CullingModel()
        model.move(by: 1, in: photos, extend: false)
        XCTAssertEqual(model.focusedID, photos[0].id)
        model.move(by: 3, in: photos, extend: true)
        XCTAssertEqual(model.focusedID, photos[3].id)
        XCTAssertEqual(model.selection, [photos[0].id, photos[3].id])
        model.move(by: 99, in: photos, extend: false)
        XCTAssertEqual(model.focusedID, photos[5].id)
        XCTAssertEqual(model.comparePhotos(in: photos).count, 1)
        model.selection = Set(photos.map(\.id))
        XCTAssertEqual(model.comparePhotos(in: photos).count, 4)
    }
}
