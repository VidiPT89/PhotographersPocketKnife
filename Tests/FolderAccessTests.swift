import XCTest
@testable import PhotographersPocketKnife

final class FolderAccessTests: XCTestCase {
    private var root: URL!
    private var store: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderAccessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Shoot/RAW"), withIntermediateDirectories: true)
        store = root.appendingPathComponent("Support/FolderAccess.plist")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDisabledOutsideTheSandbox() {
        let access = FolderAccess(enabled: false, storeURL: store)
        access.remember(root.appendingPathComponent("Shoot"))
        XCTAssertEqual(access.rememberedPaths, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
    }

    func testFolderCoversItsContentsAndSurvivesARestart() throws {
        let shoot = root.appendingPathComponent("Shoot").standardizedFileURL
        let access = FolderAccess(enabled: true, storeURL: store)
        access.remember(shoot)
        access.remember([shoot.appendingPathComponent("RAW"), shoot.appendingPathComponent("RAW/a.CR3")])
        XCTAssertEqual(access.rememberedPaths, [shoot.path])

        let reopened = FolderAccess(enabled: true, storeURL: store)
        reopened.restore()
        XCTAssertEqual(reopened.rememberedPaths, [shoot.path])
    }

    func testSiblingWithSamePrefixIsNotCovered() {
        let shoot = root.appendingPathComponent("Shoot").standardizedFileURL
        let sibling = root.appendingPathComponent("Shoot 2").standardizedFileURL
        try? FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let access = FolderAccess(enabled: true, storeURL: store)
        access.remember([shoot, sibling])
        XCTAssertEqual(access.rememberedPaths, [shoot.path, sibling.path])
    }

    func testDeletedFolderIsDroppedOnRestore() throws {
        let gone = root.appendingPathComponent("Gone").standardizedFileURL
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        FolderAccess(enabled: true, storeURL: store).remember(gone)
        try FileManager.default.removeItem(at: gone)

        let reopened = FolderAccess(enabled: true, storeURL: store)
        reopened.restore()
        XCTAssertEqual(reopened.rememberedPaths, [])
    }
}
