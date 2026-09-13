import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import PhotographersPocketKnife

/// Testes contra servidores e ficheiros reais. Só correm com variáveis de ambiente:
/// `TEST_RUNNER_PPK_INTEGRATION=1` (servidores Docker locais: SFTP 2222, FTP 2121, MinIO 9100)
/// `TEST_RUNNER_PPK_RAW_DIR=/pasta/com/raws`
@MainActor
final class TransferIntegrationTests: XCTestCase {
    private var container: ModelContainer!
    private var file: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PPK_INTEGRATION"] == "1", "Integration servers not enabled")
        container = try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        file = FileManager.default.temporaryDirectory.appendingPathComponent("ppk upload \(UUID().uuidString.prefix(6)).jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.48, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    override func tearDownWithError() throws {
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    func testSFTPUpload() async throws {
        let destination = makeDestination(.sftp, host: "localhost", port: 2222, user: "ppk", password: "ppkpass", template: "/upload/{date}/{event}")
        destination.trustUnknownHostKey = true
        try await uploadAndVerify(destination, password: "ppkpass")
    }

    func testFTPUpload() async throws {
        let destination = makeDestination(.ftp, host: "localhost", port: 2121, user: "ppk", password: "ppkpass", template: "/{date}/{event}")
        try await uploadAndVerify(destination, password: "ppkpass")
    }

    func testS3Upload() async throws {
        let destination = makeDestination(.s3, host: "http://localhost:9100", port: 9100, user: "ppkadmin", password: "ppkpass123", template: "/{year}/{event}")
        destination.bucket = "ppk-bucket"
        try await uploadAndVerify(destination, password: "ppkpass123")
    }

    func testUnreachableServerRetriesThenFails() async throws {
        let destination = makeDestination(.ftp, host: "127.0.0.1", port: 1, user: "x", password: "y", template: "/")
        let queue = TransferQueue()
        queue.maxAttempts = 2
        queue.attach(context: container.mainContext)
        queue.enqueue(files: [file], destination: destination, event: "")
        let item = try XCTUnwrap(queue.items.first)
        try await waitUntil(timeout: 30) { if case .failed = item.status { true } else { false } }
        XCTAssertEqual(item.attempts, 2)
        let records = try container.mainContext.fetch(FetchDescriptor<UploadRecord>())
        XCTAssertEqual(records.first?.success, false)
    }

    // MARK: Utilitários

    private func makeDestination(_ proto: TransferProtocol, host: String, port: Int, user: String, password: String, template: String) -> UploadDestination {
        let destination = UploadDestination(name: "Test \(proto.displayName)", transferProtocol: proto)
        destination.host = host
        destination.port = port
        destination.username = user
        destination.remoteFolderTemplate = template
        container.mainContext.insert(destination)
        try? container.mainContext.save()
        Keychain.setPassword(password, account: destination.id.uuidString)
        addTeardownBlock { [id = destination.id] in Keychain.deletePassword(account: id.uuidString) }
        return destination
    }

    private func uploadAndVerify(_ destination: UploadDestination, password: String) async throws {
        let queue = TransferQueue()
        queue.attach(context: container.mainContext)
        queue.enqueue(files: [file], destination: destination, event: "Jogo Final")
        let item = try XCTUnwrap(queue.items.first)
        XCTAssertTrue(item.remotePath.contains("Jogo Final"))

        try await waitUntil(timeout: 60) {
            if case .failed = item.status { return true }
            return item.status == .done
        }
        if case .failed(let message) = item.status { XCTFail("Upload failed: \(message)") }
        XCTAssertEqual(item.status, .done)
        XCTAssertEqual(queue.connectionState, .idle)

        // Descarrega o ficheiro enviado e compara com o original.
        let endpoint = TransferEndpoint(
            transferProtocol: destination.transferProtocol, host: destination.host, port: destination.port,
            username: destination.username, password: password, bucket: destination.bucket,
            region: destination.region, trustUnknownHostKey: destination.trustUnknownHostKey
        )
        let downloaded = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: downloaded) }
        if endpoint.transferProtocol == .sftp {
            try await CurlProcess(executable: SFTPCommand.executable, environment: SFTPCommand.environment(password: password))
                .run(arguments: SFTPCommand.arguments(endpoint), config: "get \(SFTPCommand.quote(item.remotePath)) \(SFTPCommand.quote(downloaded.path))\n")
        } else {
            var args = ["--show-error", "--fail", "--config", "-", "-o", downloaded.path]
            switch endpoint.transferProtocol {
            case .ftps: args.append("--ssl-reqd")
            case .s3: args += ["--aws-sigv4", "aws:amz:\(endpoint.region):s3"]
            case .ftp, .sftp: break
            }
            args.append(CurlCommand.url(endpoint, remotePath: item.remotePath))
            try await CurlProcess().run(arguments: args, config: CurlCommand.config(endpoint))
        }
        XCTAssertEqual(try Data(contentsOf: downloaded), try Data(contentsOf: file))

        let records = try container.mainContext.fetch(FetchDescriptor<UploadRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.success, true)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}

final class RawIntegrationTests: XCTestCase {
    func testRealRawFilesDecodeEditAndExport() throws {
        guard let dir = ProcessInfo.processInfo.environment["PPK_RAW_DIR"] else {
            throw XCTSkip("Set PPK_RAW_DIR to a folder with RAW files")
        }
        let files = PhotoImporter.imageFiles(in: URL(fileURLWithPath: dir)).filter(PhotoImporter.isRaw)
        XCTAssertFalse(files.isEmpty)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-raw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        var recipe = EditRecipe()
        recipe.exposure = 0.5
        recipe.shadows = 0.4
        recipe.vibrance = 0.3
        recipe.crop = CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

        for file in files {
            var start = Date()
            let info = MetadataReader.basicInfo(for: file)
            XCTAssertGreaterThan(info.width, 1000, file.lastPathComponent)
            XCTAssertNotNil(info.camera, file.lastPathComponent)

            let thumb = ThumbnailCache.generate(url: file, maxPixel: 320)
            XCTAssertNotNil(thumb, file.lastPathComponent)
            let thumbTime = Date().timeIntervalSince(start)

            start = Date()
            let preview = ImageRenderer.shared.renderPreview(url: file, recipe: recipe, maxPixel: 2000)
            XCTAssertNotNil(preview, file.lastPathComponent)
            let previewTime = Date().timeIntervalSince(start)

            start = Date()
            var settings = ExportSettings()
            settings.resize = true
            settings.longEdge = 3000
            let jpeg = try ImageRenderer.shared.export(url: file, recipe: recipe, settings: settings, to: output)
            let exported = MetadataReader.basicInfo(for: jpeg)
            XCTAssertEqual(max(exported.width, exported.height), 3000, file.lastPathComponent)
            XCTAssertEqual(exported.camera, info.camera, "EXIF kept in export")
            let exportTime = Date().timeIntervalSince(start)

            settings.format = .dng
            settings.longEdge = 1500
            let dng = try ImageRenderer.shared.export(url: file, recipe: recipe, settings: settings, to: output)
            XCTAssertNotNil(CIRAWFilter(imageURL: dng)?.outputImage, "Exported DNG readable")

            print("PPK raw \(file.lastPathComponent) [\(info.camera ?? "?")] \(info.width)x\(info.height) — thumb \(thumbTime)s, preview \(previewTime)s, export \(exportTime)s")
        }
    }
}
