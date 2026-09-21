import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotographersPocketKnife

final class EngineTests: XCTestCase {

    // MARK: Curvas, LUT e histórico

    func testLinearCurveIsIdentityAndMonotoneCurveDoesNotOvershoot() {
        let linear = MonotoneCurve(EditRecipe.linearCurve)
        for x in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(linear.evaluate(x), x, accuracy: 1e-9)
        }
        let sCurve = MonotoneCurve([CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.15), CurvePoint(x: 0.75, y: 0.85), CurvePoint(x: 1, y: 1)])
        var previous = -1.0
        for x in stride(from: 0.0, through: 1.0, by: 0.01) {
            let y = sCurve.evaluate(x)
            XCTAssertGreaterThanOrEqual(y, previous)
            XCTAssertTrue((0...1).contains(y))
            previous = y
        }
        XCTAssertEqual(sCurve.evaluate(0.25), 0.15, accuracy: 1e-9)
    }

    func testIdentityCubeLeavesColorsUnchanged() {
        let data = ColorCube.data(for: EditRecipe())
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = ColorCube.dimension
        let index = (5 * n * n + 10 * n + 20) * 4 // b=5, g=10, r=20
        XCTAssertEqual(values[index], Float(20) / Float(n - 1), accuracy: 1e-5)
        XCTAssertEqual(values[index + 1], Float(10) / Float(n - 1), accuracy: 1e-5)
        XCTAssertEqual(values[index + 2], Float(5) / Float(n - 1), accuracy: 1e-5)
    }

    func testHSLRoundTripAndBandAdjustment() {
        let rgb = (0.8, 0.3, 0.1)
        let (h, s, l) = ColorCube.rgbToHSL(rgb)
        let back = ColorCube.hslToRGB(h, s, l)
        XCTAssertEqual(back.0, rgb.0, accuracy: 1e-9)
        XCTAssertEqual(back.1, rgb.1, accuracy: 1e-9)
        XCTAssertEqual(back.2, rgb.2, accuracy: 1e-9)

        var adjustments = Array(repeating: HSLAdjustment(), count: HSLBand.allCases.count)
        adjustments[HSLBand.blue.rawValue].saturation = -1
        let blue = ColorCube.applyHSL((0.1, 0.1, 0.9), adjustments)
        XCTAssertEqual(ColorCube.rgbToHSL(blue).1, 0, accuracy: 1e-6, "Blues desaturated")
        let red = ColorCube.applyHSL((0.9, 0.1, 0.1), adjustments)
        XCTAssertEqual(red.0, 0.9, accuracy: 1e-6, "Reds untouched")
    }

    func testEditHistoryUndoRedoAndBranching() {
        var history = EditHistory()
        var recipe = EditRecipe()
        recipe.exposure = 1
        history.push("adjust.exposure", recipe)
        recipe.contrast = 0.5
        history.push("adjust.contrast", recipe)
        history.push("adjust.contrast", recipe) // igual: ignorado
        XCTAssertEqual(history.entries.count, 3)

        XCTAssertEqual(history.undo().contrast, 0)
        XCTAssertTrue(history.canRedo)
        recipe = history.current
        recipe.vibrance = 0.3
        history.push("adjust.vibrance", recipe)
        XCTAssertFalse(history.canRedo, "A new edit discards the redo branch")
        XCTAssertEqual(history.entries.map(\.labelKey), ["history.original", "adjust.exposure", "adjust.vibrance"])
        XCTAssertEqual(history.jump(to: 0), .identity)
    }

    func testPresetKeepsTargetCrop() {
        var target = EditRecipe()
        target.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        var preset = EditRecipe()
        preset.exposure = 0.7
        preset.crop = CropRect()
        let result = target.applyingSettings(from: preset)
        XCTAssertEqual(result.exposure, 0.7)
        XCTAssertEqual(result.crop, target.crop)
    }

    // MARK: Render e exportação

    func testRendererAppliesExposureTemperatureAndCrop() throws {
        let gray = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 80))
        let renderer = ImageRenderer.shared

        var brighter = EditRecipe()
        brighter.exposure = 1
        XCTAssertGreaterThan(try pixel(renderer.apply(brighter, to: gray)).r, try pixel(gray).r)

        var warm = EditRecipe()
        warm.temperature = 0.6
        let warmPixel = try pixel(renderer.apply(warm, to: gray))
        XCTAssertGreaterThan(warmPixel.r, warmPixel.b, "Positive temperature warms the image")

        var cropped = EditRecipe()
        cropped.crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.25)
        let extent = renderer.apply(cropped, to: gray).extent
        XCTAssertEqual(extent.width, 50)
        XCTAssertEqual(extent.height, 20)
    }

    func testExportWritesResizedJPEG() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        var settings = ExportSettings()
        settings.resize = true
        settings.longEdge = 100
        settings.suffix = "_web"
        var recipe = EditRecipe()
        recipe.saturation = -1
        let output = try ImageRenderer.shared.export(url: source, recipe: recipe, settings: settings, to: folder)

        XCTAssertEqual(output.lastPathComponent, "source_web.jpg")
        let info = MetadataReader.basicInfo(for: output)
        XCTAssertEqual(info.width, 100)
        XCTAssertEqual(info.height, 50)
    }

    func testExportWritesReadableDNG() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-dng-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("source.png")
        // Tamanho realista: o ImageIO lê DNGs minúsculos como TIFF.
        let context = try XCTUnwrap(CGContext(data: nil, width: 2048, height: 1366, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1366))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 683, width: 2048, height: 683)) // metade de cima vermelha
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        var settings = ExportSettings()
        settings.format = .dng
        let output = try ImageRenderer.shared.export(url: source, recipe: EditRecipe(), settings: settings, to: folder)
        XCTAssertEqual(output.pathExtension, "dng")

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, "com.adobe.raw-image")

        let raw = try XCTUnwrap(CIRAWFilter(imageURL: output))
        let decoded = try XCTUnwrap(raw.outputImage)
        XCTAssertEqual(decoded.extent.width, 2048)
        XCTAssertEqual(decoded.extent.height, 1366)
        let top = try pixel(decoded.cropped(to: CGRect(x: 0, y: 1200, width: 2048, height: 100)))
        let bottom = try pixel(decoded.cropped(to: CGRect(x: 0, y: 0, width: 2048, height: 100)))
        XCTAssertGreaterThan(top.r, top.b, "Top half stays red (row order and channels preserved)")
        XCTAssertGreaterThan(bottom.b, bottom.r)
    }

    // MARK: Envio

    func testRemoteFolderTemplate() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        XCTAssertEqual(RemotePath.folder(template: "/clientes/{year}/{date}/{event}", date: date, event: "Benfica: Porto"), "/clientes/2026/2026-03-07/Benfica- Porto")
        XCTAssertEqual(RemotePath.folder(template: "{date}/{event}/", date: date, event: ""), "/2026-03-07")
        XCTAssertEqual(RemotePath.join("/a/b/", "foto 1.jpg"), "/a/b/foto 1.jpg")
        // Um evento escrito à mão não deve conseguir sair da pasta remota escolhida.
        XCTAssertEqual(RemotePath.folder(template: "/fotos/{event}", date: date, event: ".."), "/fotos")
        XCTAssertEqual(RemotePath.join("/a/b", ".."), "/a/b/unnamed")
    }

    func testCommandsCannotBeInjectedThroughNewlines() {
        // O batch do sftp é uma linha por comando: um nome com mudança de linha não pode acrescentar comandos.
        XCTAssertEqual(SFTPCommand.quote("/up/a.jpg\nrm /up/tudo"), "\"/up/a.jpgrm /up/tudo\"")
        // A configuração do curl é uma diretiva por linha: a password vai escapada, não parte a linha.
        let endpoint = TransferEndpoint(transferProtocol: .ftp, host: "example.com", port: 21, username: "vidi",
                                        password: "p\nupload-file = /etc/passwd", bucket: "", region: "", trustUnknownHostKey: false)
        let config = CurlCommand.config(endpoint)
        XCTAssertEqual(config.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(config.contains("\\n"))
    }

    func testCurlArgumentsPerProtocolKeepPasswordOutOfArguments() {
        var endpoint = TransferEndpoint(transferProtocol: .ftp, host: "example.com", port: 21, username: "vidi", password: "p@ss\"word",
                                        bucket: "", region: "eu-west-1", trustUnknownHostKey: true)
        let file = URL(fileURLWithPath: "/tmp/foto 1.jpg")

        let ftp = CurlCommand.uploadArguments(endpoint, file: file, remotePath: "/2026/foto 1.jpg", resume: true)
        XCTAssertEqual(ftp.last, "ftp://example.com:21/2026/foto%201.jpg")
        XCTAssertTrue(ftp.contains("--ftp-create-dirs"))
        XCTAssertTrue(ftp.contains("-C"))
        XCTAssertFalse(ftp.joined().contains("p@ss"))
        XCTAssertEqual(CurlCommand.config(endpoint), "user = \"vidi:p@ss\\\"word\"\n")
        XCTAssertEqual(TransferCommand.upload(endpoint, file: file, remotePath: "/a.jpg", resume: false).executable, "/usr/bin/curl")

        endpoint.transferProtocol = .ftps
        XCTAssertTrue(CurlCommand.uploadArguments(endpoint, file: file, remotePath: "/a.jpg", resume: false).contains("--ssl-reqd"))

        endpoint.transferProtocol = .s3
        endpoint.host = "s3.eu-west-1.amazonaws.com"
        endpoint.port = 443
        endpoint.bucket = "fotos"
        let s3 = CurlCommand.uploadArguments(endpoint, file: file, remotePath: "/a.jpg", resume: true)
        XCTAssertEqual(s3.last, "https://s3.eu-west-1.amazonaws.com:443/fotos/a.jpg")
        XCTAssertTrue(s3.contains("aws:amz:eu-west-1:s3"))
        XCTAssertFalse(s3.contains("-C"))
    }

    func testSFTPUsesSystemOpenSSHWithBatchAndAskpass() throws {
        let endpoint = TransferEndpoint(transferProtocol: .sftp, host: "example.com", port: 2222, username: "vidi", password: "segredo",
                                        bucket: "", region: "", trustUnknownHostKey: true)
        let command = TransferCommand.upload(endpoint, file: URL(fileURLWithPath: "/tmp/a \"b\".jpg"), remotePath: "/up/2026/a.jpg", resume: false)
        XCTAssertEqual(command.executable, "/usr/bin/sftp")
        XCTAssertEqual(command.arguments.last, "vidi@example.com")
        XCTAssertLessThan(try XCTUnwrap(command.arguments.firstIndex(of: "BatchMode=no")), try XCTUnwrap(command.arguments.firstIndex(of: "-b")))
        XCTAssertTrue(command.arguments.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertFalse(command.arguments.joined().contains("segredo"))
        XCTAssertEqual(command.input, "-mkdir \"/up\"\n-mkdir \"/up/2026\"\nput \"/tmp/a \\\"b\\\".jpg\" \"/up/2026/a.jpg\"\n")

        let environment = try XCTUnwrap(command.environment)
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: try XCTUnwrap(environment["SSH_ASKPASS"])))
        XCTAssertNil(SFTPCommand.environment(password: ""), "Key-based auth needs no askpass")
    }

    func testCurlProgressParsingAndRetryableErrors() {
        XCTAssertEqual(CurlCommand.parseProgress("\r####       12.5%\r########    45,0%"), 0.45)
        XCTAssertNil(CurlCommand.parseProgress("curl: (6) Could not resolve host"))
        XCTAssertTrue(TransferError.curl(code: 28, message: "").isRetryable)
        XCTAssertFalse(TransferError.curl(code: 67, message: "").isRetryable)
    }

    func testCurlProcessReportsFailure() async {
        let endpoint = TransferEndpoint(transferProtocol: .ftp, host: "127.0.0.1", port: 1, username: "a", password: "b",
                                        bucket: "", region: "", trustUnknownHostKey: false)
        do {
            try await CurlProcess().run(arguments: CurlCommand.testArguments(endpoint), config: CurlCommand.config(endpoint))
            XCTFail("Connection to a closed port must fail")
        } catch let error as TransferError {
            guard case .curl(let code, _) = error else { return XCTFail("Expected curl error, got \(error)") }
            XCTAssertEqual(code, 7)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testThumbnailCachePruneDropsTheOldestFiles() throws {
        let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }

        // Três miniaturas de 1 KB, escritas há 30, 10 e 0 dias.
        for (name, ageInDays) in [("old", 30.0), ("mid", 10.0), ("new", 0.0)] {
            let file = cache.appendingPathComponent("\(name).jpg")
            try Data(repeating: 0, count: 1024).write(to: file)
            let used = Date().addingTimeInterval(-ageInDays * 86_400)
            try FileManager.default.setAttributes([.modificationDate: used], ofItemAtPath: file.path)
        }

        ThumbnailCache.prune(cache, maxBytes: 2048)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: cache.path))
        XCTAssertFalse(left.contains("old.jpg"), "The oldest thumbnail goes first")
        XCTAssertTrue(left.contains("new.jpg"))
        XCTAssertLessThanOrEqual(left.count, 2)
    }

    private func pixel(_ image: CIImage) throws -> (r: Float, g: Float, b: Float) {
        var bytes = [Float](repeating: 0, count: 4)
        let rect = CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1)
        ImageRenderer.shared.context.render(image, toBitmap: &bytes, rowBytes: 16, bounds: rect, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (bytes[0], bytes[1], bytes[2])
    }
}
