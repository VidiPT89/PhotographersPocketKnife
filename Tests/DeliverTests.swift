import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import PhotographersPocketKnife

final class DeliverTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-deliver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testOlderExportSettingsStillDecode() throws {
        let legacy = Data(#"{"format":"png","quality":0.8,"resize":true,"longEdge":1200,"suffix":"_web","includeMetadata":false,"sixteenBit":false}"#.utf8)
        let settings = try JSONDecoder().decode(ExportSettings.self, from: legacy)
        XCTAssertEqual(settings.format, .png)
        XCTAssertEqual(settings.longEdge, 1200)
        XCTAssertEqual(settings.metadataRule, .none, "includeMetadata=false maps to removing metadata")
        XCTAssertEqual(settings.colorSpace, .sRGB)

        var modern = ExportSettings()
        modern.watermarkEnabled = true
        modern.colorSpace = .displayP3
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(modern)), modern)
    }

    func testExportAppliesColourSpaceDPIPercentResizeAndWatermark() throws {
        let source = try writeImage(named: "source.jpg", width: 800, height: 600, gps: false)
        var settings = ExportSettings()
        settings.resize = true
        settings.resizeMode = .percent
        settings.resizePercent = 50
        settings.dpi = 240
        settings.colorSpace = .displayP3
        settings.outputSharpening = .screen

        let plain = try ImageRenderer.shared.export(url: source, recipe: EditRecipe(), settings: settings, to: folder)
        let properties = MetadataReader.properties(for: plain)
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 400)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 300)
        XCTAssertEqual(properties[kCGImagePropertyDPIWidth as String] as? Int, 240)
        XCTAssertTrue((properties[kCGImagePropertyProfileName as String] as? String)?.contains("P3") == true)

        settings.watermarkEnabled = true
        settings.watermarkText = "WATERMARK"
        settings.watermarkPosition = .center
        settings.watermarkSize = 0.1
        settings.watermarkOpacity = 1
        let marked = try ImageRenderer.shared.export(url: source, recipe: EditRecipe(), settings: settings, to: folder)
        XCTAssertNotEqual(try centreBrightness(marked), try centreBrightness(plain), "Watermark changes the centre of the image")
    }

    func testMetadataRules() throws {
        let source = try writeImage(named: "gps.jpg", width: 200, height: 100, gps: true)
        var settings = ExportSettings()

        settings.metadataRule = .all
        let all = MetadataReader.properties(for: try ImageRenderer.shared.export(url: source, recipe: EditRecipe(), settings: settings, to: folder))
        XCTAssertNotNil(all[kCGImagePropertyGPSDictionary as String])

        settings.metadataRule = .noGPS
        let noGPS = MetadataReader.properties(for: try ImageRenderer.shared.export(url: source, recipe: EditRecipe(), settings: settings, to: folder))
        XCTAssertNil(noGPS[kCGImagePropertyGPSDictionary as String])
        XCTAssertNotNil(noGPS[kCGImagePropertyExifDictionary as String])

        let copyright = ImageRenderer.metadata(from: [
            kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCCopyrightNotice as String: "© 2026", kCGImagePropertyIPTCCity as String: "Lisboa"],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 38.7],
        ], rule: .copyrightOnly)
        let iptc = copyright[kCGImagePropertyIPTCDictionary] as? [String: Any]
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCCopyrightNotice as String] as? String, "© 2026")
        XCTAssertNil(iptc?[kCGImagePropertyIPTCCity as String])
        XCTAssertNil(copyright[kCGImagePropertyGPSDictionary])
        XCTAssertTrue(ImageRenderer.metadata(from: [kCGImagePropertyGPSDictionary as String: [:]], rule: .none).isEmpty)
    }

    func testWebDAVCommandCreatesFoldersAndKeepsPasswordOffTheCommandLine() {
        let endpoint = TransferEndpoint(transferProtocol: .webdav, host: "dav.example.com", port: 443, username: "vidi", password: "segredo",
                                        bucket: "", region: "", trustUnknownHostKey: false)
        let command = TransferCommand.upload(endpoint, file: URL(fileURLWithPath: "/tmp/foto 1.jpg"), remotePath: "/2026/Final/foto 1.jpg", resume: true)
        XCTAssertEqual(command.executable, "/usr/bin/curl")
        XCTAssertEqual(command.arguments, ["--config", "-"])
        XCTAssertEqual(command.input.components(separatedBy: "request = \"MKCOL\"").count - 1, 2, "One MKCOL per parent folder")
        XCTAssertTrue(command.input.contains("url = \"https://dav.example.com:443/2026/Final/\""))
        XCTAssertTrue(command.input.contains("upload-file = \"/tmp/foto 1.jpg\""))
        XCTAssertTrue(command.input.contains("url = \"https://dav.example.com:443/2026/Final/foto%201.jpg\""))
        XCTAssertTrue(command.input.contains("next\n"))
        XCTAssertFalse(command.arguments.joined().contains("segredo"))
        XCTAssertEqual(TransferProtocol.webdav.displayName, "WebDAV")
    }

    @MainActor
    func testDestinationAddressParsingAndValidation() throws {
        let sftp = try XCTUnwrap(DestinationAddress.parse(" sftp://ana:segredo@fotos.pt:2222/entregas/2026 "))
        XCTAssertEqual(sftp, ParsedDestination(transferProtocol: .sftp, host: "fotos.pt", port: 2222, username: "ana", password: "segredo", folder: "/entregas/2026"))
        XCTAssertEqual(DestinationAddress.parse("ftp://srv.pt")?.port, 21)
        XCTAssertNil(DestinationAddress.parse("ftp://srv.pt")?.folder)
        let dav = try XCTUnwrap(DestinationAddress.parse("http://localhost:8088/dav"))
        XCTAssertEqual(dav.transferProtocol, .webdav)
        XCTAssertEqual(dav.host, "http://localhost:8088")
        XCTAssertEqual(dav.folder, "/dav")
        XCTAssertEqual(DestinationAddress.parse("https://cloud.pt")?.host, "https://cloud.pt")
        XCTAssertNil(DestinationAddress.parse("fotos.pt"))
        XCTAssertNil(DestinationAddress.parse("mailto:ana@fotos.pt"))

        XCTAssertEqual(DestinationAddress.label(transferProtocol: .sftp, host: "fotos.pt", port: 22, username: "ana", bucket: ""), "ana@fotos.pt")
        XCTAssertEqual(DestinationAddress.label(transferProtocol: .sftp, host: "fotos.pt", port: 2222, username: "ana", bucket: ""), "ana@fotos.pt:2222")
        XCTAssertEqual(DestinationAddress.label(transferProtocol: .s3, host: "s3.pt", port: 443, username: "key", bucket: "entregas"), "entregas · s3.pt")

        XCTAssertEqual(DestinationValidation.issues(transferProtocol: .sftp, host: "", port: 0, username: "", bucket: "", template: "/{date}/{cliente}"),
                       [.init(key: "destination.issue.host"), .init(key: "destination.issue.port"), .init(key: "destination.issue.user"),
                        .init(key: "destination.issue.token", argument: "{cliente}")])
        XCTAssertEqual(DestinationValidation.issues(transferProtocol: .s3, host: "http://localhost:9100", port: 443, username: "key", bucket: "", template: "/{year}").map(\.key),
                       ["destination.issue.bucket"])
        XCTAssertEqual(DestinationValidation.issues(transferProtocol: .ftp, host: "ftp://srv.pt", port: 21, username: "ana", bucket: "", template: "/").map(\.key),
                       ["destination.issue.address"])
        XCTAssertTrue(DestinationValidation.issues(transferProtocol: .webdav, host: "https://cloud.pt", port: 443, username: "", bucket: "", template: "/{event}").isEmpty)
        XCTAssertEqual(DestinationValidation.unknownTokens(in: "/{x}/{date}/{x}/{y"), ["{x}"])
    }

    @MainActor
    func testDestinationStatsDefaultsHistoryFilterAndQueueGroups() {
        let id = UUID()
        let now = Date()
        let entries: [DestinationStats.Entry] = [
            .init(destinationID: id, destinationName: "Antigo nome", success: true, bytes: 100, date: now),
            .init(destinationID: nil, destinationName: "Cliente", success: true, bytes: 50, date: now.addingTimeInterval(-60)),
            .init(destinationID: nil, destinationName: "Cliente", success: false, bytes: 999, date: now),
            .init(destinationID: UUID(), destinationName: "Cliente", success: true, bytes: 70, date: now),
        ]
        XCTAssertEqual(DestinationStats.compute(entries, id: id, name: "Cliente"), DestinationStats(uploaded: 2, failed: 1, bytes: 150, lastUpload: now))

        let a = UUID(), b = UUID()
        XCTAssertEqual(DestinationDefaults.preferredID(among: [a, b], stored: b), b)
        XCTAssertEqual(DestinationDefaults.preferredID(among: [a, b], stored: UUID()), a, "A deleted default falls back to the first destination")
        XCTAssertNil(DestinationDefaults.preferredID(among: [], stored: a))
        XCTAssertEqual(DestinationDefaults.copyName("Cliente", suffix: "cópia", existing: ["Cliente", "Cliente (cópia)"]), "Cliente (cópia) 2")

        func match(query: String = "", destination: String? = nil, status: UploadHistoryFilter.Status = .all) -> Bool {
            UploadHistoryFilter.matches(fileName: "IMG_1.jpg", remotePath: "/2026/Casamento/IMG_1.jpg", destinationName: "Cliente",
                                        success: true, query: query, destination: destination, status: status)
        }
        XCTAssertTrue(match(query: "casamento", destination: "Cliente", status: .ok))
        XCTAssertFalse(match(status: .failed))
        XCTAssertFalse(match(destination: "Outro"))
        XCTAssertFalse(match(query: "batizado"))

        let file = URL(fileURLWithPath: "/tmp/1.jpg")
        let items = [
            TransferItem(fileURL: file, destinationID: a, destinationName: "A", remotePath: "/1.jpg", bytes: 1),
            TransferItem(fileURL: file, destinationID: b, destinationName: "B", remotePath: "/1.jpg", bytes: 1),
            TransferItem(fileURL: file, destinationID: a, destinationName: "A", remotePath: "/2.jpg", bytes: 1),
        ]
        let groups = TransferGroup.make(items)
        XCTAssertEqual(groups.map(\.name), ["A", "B"])
        XCTAssertEqual(groups[0].items.map(\.remotePath), ["/1.jpg", "/2.jpg"])
    }

    @MainActor
    func testTransferSpeedAndRemainingTime() {
        let item = TransferItem(fileURL: URL(fileURLWithPath: "/tmp/x.jpg"), destinationID: UUID(), destinationName: "D", remotePath: "/x.jpg", bytes: 10_000_000)
        let start = Date()
        item.updateProgress(0, now: start)
        item.updateProgress(0.2, now: start.addingTimeInterval(1))
        XCTAssertEqual(item.bytesPerSecond, 2_000_000, accuracy: 1)
        XCTAssertEqual(item.remainingSeconds ?? 0, 4, accuracy: 0.01)
        item.updateProgress(0.1, now: start.addingTimeInterval(2))
        XCTAssertEqual(item.progress, 0.2, "Progress never goes backwards")
        XCTAssertFalse(TransferFormat.speed(2_000_000).isEmpty)
    }

    func testUploadReportCSVEscapesFields() {
        let csv = UploadReport.csv([
            UploadReport.Row(date: Date(timeIntervalSince1970: 0), fileName: "a,b.jpg", destination: "Agência \"Lusa\"", remotePath: "/2026/a.jpg",
                             bytes: 1234, success: false, error: "curl: (7) Failed"),
        ])
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.first, "date,file,destination,remote_path,bytes,status,error")
        XCTAssertEqual(lines.last, "1970-01-01T00:00:00Z,\"a,b.jpg\",\"Agência \"\"Lusa\"\"\",/2026/a.jpg,1234,failed,curl: (7) Failed")
    }

    @MainActor
    func testHotFolderOnlyTakesPhotosWithTheChosenLabelOnce() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HotFolderTests"))
        defaults.removePersistentDomain(forName: "HotFolderTests")
        let service = HotFolderService(defaults: defaults)
        XCTAssertEqual(service.label, .green)
        XCTAssertFalse(service.isEnabled)

        let container = try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let info = ImportedPhotoInfo(url: URL(fileURLWithPath: "/tmp/hot.jpg"), captureDate: nil, camera: nil, lens: nil, width: 1, height: 1, fileSize: 1)
        let photo = Photo(info: info, sessionName: "S")
        container.mainContext.insert(photo)
        photo.colorLabel = .green

        XCTAssertFalse(service.shouldProcess(photo), "Disabled")
        service.isEnabled = true
        service.destinationID = UUID()
        XCTAssertTrue(service.shouldProcess(photo))
        photo.colorLabel = .red
        XCTAssertFalse(service.shouldProcess(photo), "Wrong label")

        XCTAssertTrue(HotFolderService(defaults: defaults).isEnabled, "Settings persist")
    }

    // MARK: Utilitários

    private func writeImage(named name: String, width: Int, height: Int, gps: Bool) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.15, green: 0.18, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [800]]]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 38.7, kCGImagePropertyGPSLatitudeRef: "N"]
        }
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func centreBrightness(_ url: URL) throws -> Double {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let histogram = Histogram.compute(image)
        return histogram.luma.enumerated().reduce(0) { $0 + Double($1.offset) * Double($1.element) }
    }
}
