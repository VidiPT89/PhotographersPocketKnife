import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotographersPocketKnife

final class CatalogTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Renomear

    func testRenameTemplateResolvesTokens() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 15, minute: 4, second: 5))
        let name = RenameTemplate.resolve("{date}_{time}_{seq}_{event}/{camera}", date: date, sequence: 7, event: "Casamento", originalName: "IMG_1", camera: "X100")
        XCTAssertEqual(name, "20260913_150405_0007_Casamento-X100")
    }

    func testRenameEmptyTemplateKeepsOriginalName() {
        XCTAssertEqual(RenameTemplate.resolve("  ", date: nil, sequence: 1, event: "", originalName: "IMG_1", camera: nil), "IMG_1")
    }

    func testRenameDetectsDuplicateTargetsAndExistingFiles() {
        let a = BatchRenamer.Plan(from: URL(fileURLWithPath: "/x/a.jpg"), to: URL(fileURLWithPath: "/x/same.jpg"))
        let b = BatchRenamer.Plan(from: URL(fileURLWithPath: "/x/b.jpg"), to: URL(fileURLWithPath: "/x/SAME.jpg"))
        let c = BatchRenamer.Plan(from: URL(fileURLWithPath: "/x/c.jpg"), to: URL(fileURLWithPath: "/x/taken.jpg"))
        let conflicts = BatchRenamer.conflicts([a, b, c]) { $0.lastPathComponent == "taken.jpg" }
        XCTAssertEqual(conflicts, [b, c])
    }

    func testRenameSwapChainAppliesOnDisk() throws {
        let one = folder.appendingPathComponent("1.jpg"), two = folder.appendingPathComponent("2.jpg")
        try Data("one".utf8).write(to: one)
        try Data("two".utf8).write(to: two)
        try Data("xmp".utf8).write(to: folder.appendingPathComponent("1.xmp"))

        let plans = [BatchRenamer.Plan(from: one, to: two), BatchRenamer.Plan(from: two, to: one)]
        XCTAssertTrue(BatchRenamer.conflicts(plans).isEmpty)
        try BatchRenamer.apply(plans)

        XCTAssertEqual(try String(contentsOf: two, encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: one, encoding: .utf8), "two")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("2.xmp").path))
    }

    // MARK: Importação e metadados

    func testImporterFindsSupportedFilesAndCopiesByDate() throws {
        let source = folder.appendingPathComponent("card")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        try writeJPEG(to: source.appendingPathComponent("DCIM/a.jpg"))
        try Data("not an image".utf8).write(to: source.appendingPathComponent("notes.txt"))

        let destination = folder.appendingPathComponent("library")
        let infos = try PhotoImporter.run(folder: source, options: .init(copyDestination: destination, subfolderByDate: true)) { _, _ in }

        XCTAssertEqual(infos.count, 1)
        XCTAssertTrue(infos[0].url.path.hasPrefix(destination.path))
        XCTAssertEqual(infos[0].width, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: infos[0].url.path))

        // Reimportar não duplica o ficheiro copiado.
        let again = try PhotoImporter.run(folder: source, options: .init(copyDestination: destination, subfolderByDate: true)) { _, _ in }
        XCTAssertEqual(again[0].url, infos[0].url)
    }

    func testIPTCWriteIsReadBack() throws {
        let file = folder.appendingPathComponent("photo.jpg")
        try writeJPEG(to: file)
        var fields = IPTCFields()
        fields.title = "Final da Taça"
        fields.creator = "David Arsénio Martins"
        fields.copyright = "© 2026"
        fields.keywords = "futebol, estádio"
        fields.city = "Cascais"
        try MetadataWriter.write(fields, to: file)

        let details = Dictionary(uniqueKeysWithValues: MetadataReader.details(for: file).map { ($0.id, $0.value) })
        XCTAssertEqual(details["meta.title"], "Final da Taça")
        XCTAssertEqual(details["meta.creator"], "David Arsénio Martins")
        XCTAssertEqual(details["meta.copyright"], "© 2026")
        XCTAssertEqual(details["meta.city"], "Cascais")
        XCTAssertTrue(details["meta.keywords"]?.contains("estádio") == true)
        XCTAssertEqual(details["meta.dimensions"], "64 × 48")
    }

    func testRawMetadataGoesToSidecar() throws {
        let raw = folder.appendingPathComponent("IMG_0001.CR3")
        try Data("fake raw".utf8).write(to: raw)
        var fields = IPTCFields()
        fields.city = "Lisboa"
        try MetadataWriter.write(fields, to: raw)
        let metadata = try XCTUnwrap(MetadataWriter.readMetadata(for: raw))
        XCTAssertEqual(MetadataReader.xmpString(metadata, "photoshop:City"), "Lisboa")
        XCTAssertEqual(try Data(contentsOf: raw), Data("fake raw".utf8))
    }

    // MARK: Duplicados

    func testPerceptualHashGroupsSimilarImages() throws {
        let a = try makeImage(64, 48, seed: 1), b = try makeImage(64, 48, seed: 1), c = try makeImage(64, 48, seed: 9)
        let ha = PerceptualHash.dHash(a), hb = PerceptualHash.dHash(b), hc = PerceptualHash.dHash(c)
        XCTAssertEqual(ha, hb)
        let groups = PerceptualHash.groups([(id: "a", hash: ha), (id: "b", hash: hb), (id: "c", hash: hc)], threshold: 4)
        XCTAssertNotNil(groups["a"])
        XCTAssertEqual(groups["a"], groups["b"])
        XCTAssertNil(groups["c"])
    }

    // MARK: Utilitários

    private func makeImage(_ width: Int, _ height: Int, seed: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<width {
            let v = CGFloat((x * seed * 37) % 255) / 255
            context.setFillColor(CGColor(red: v, green: 1 - v, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func writeJPEG(to url: URL) throws {
        let image = try makeImage(64, 48, seed: 3)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
