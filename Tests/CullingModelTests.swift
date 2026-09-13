import XCTest
import SwiftData
@testable import PhotographersPocketKnife

@MainActor
final class CullingModelTests: XCTestCase {
    private var container: ModelContainer!
    private var photos: [Photo] = []

    override func setUpWithError() throws {
        container = try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let infos = (1...6).map { i in
            ImportedPhotoInfo(url: URL(fileURLWithPath: "/tmp/IMG_\(i).jpg"), captureDate: Date(timeIntervalSince1970: Double(i) * 60),
                              camera: i % 2 == 0 ? "Nikon Z9" : "Sony A1", lens: nil, width: 10, height: 10, fileSize: 1)
        }
        CatalogService.insert(infos, session: "Jogo", into: container.mainContext)
        // Reimportar os mesmos caminhos não duplica.
        XCTAssertEqual(CatalogService.insert(infos, session: "Jogo", into: container.mainContext), 0)
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
