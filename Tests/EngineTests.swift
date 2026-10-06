import XCTest
import CoreImage
import ImageIO
import CoreText
import UniformTypeIdentifiers
@testable import PhotographersPocketKnife

final class EngineTests: XCTestCase {

    // MARK: Remoção generativa

    func testWindowFeatheringNeverRevealsUnfilledOriginal() throws {
        let extent = CGRect(x: 0, y: 0, width: 1200, height: 600)
        let window = CGRect(x: 200, y: 100, width: 400, height: 400)
        let white = CIImage(color: .white).cropped(to: extent)
        let black = CIImage(color: .black).cropped(to: extent)
        let fresh = GenerativeInpainter.blendMask(white, window: window, extent: extent, covered: black)
        let overlapping = GenerativeInpainter.blendMask(white, window: window, extent: extent, covered: white)
        let edge = CGRect(x: 201, y: 299, width: 1, height: 1)
        XCTAssertEqual(try pixel(fresh.cropped(to: edge)).r, 1, accuracy: 0.001)
        XCTAssertLessThan(try pixel(overlapping.cropped(to: edge)).r, 0.5)
        let empty = GenerativeInpainter.blendMask(black, window: window, extent: extent, covered: black)
        XCTAssertEqual(try pixel(empty).r, 0, accuracy: 0.001)
    }

    func testLongStrokeWindowsIncludeContextBeyondBothTips() {
        let extent = CGRect(x: 0, y: 0, width: 1600, height: 600)
        let bounds = CGRect(x: 100, y: 280, width: 1400, height: 40)
        let windows = GenerativeInpainter.windows(for: bounds, in: extent)
        XCTAssertGreaterThan(windows.count, 1)
        XCTAssertLessThan(windows.first!.minX, bounds.minX - 30)
        XCTAssertGreaterThan(windows.last!.maxX, bounds.maxX + 30)
        XCTAssertTrue(windows.allSatisfy { extent.contains($0) })
    }

    func testSelectionCacheDistinguishesSimilarExposuresAndOrigins() {
        let extent = CGRect(x: 0, y: 0, width: 600, height: 400)
        let a = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: extent)
        let b = CIImage(color: CIColor(red: 0.205, green: 0.205, blue: 0.205)).cropped(to: extent)
        XCTAssertNotEqual(SmartSelection.fingerprint(a), SmartSelection.fingerprint(b))
        XCTAssertEqual(SmartSelection.fingerprint(a), SmartSelection.fingerprint(a))
        XCTAssertNotEqual(SmartSelection.fingerprint(a), SmartSelection.fingerprint(a.transformed(by: .init(translationX: 0.5, y: 0))))
    }

    func testDistantRemovalRegionsKeepLocalContextAndTranslatedCoordinates() {
        let extent = CGRect(x: 100, y: 200, width: 2000, height: 1200)
        let a = CGRect(x: 200, y: 300, width: 100, height: 100)
        let b = CGRect(x: 1800, y: 1200, width: 100, height: 100)
        let mask = CIImage(color: .white).cropped(to: a)
            .composited(over: CIImage(color: .white).cropped(to: b))
            .composited(over: CIImage(color: .black).cropped(to: extent))
        let regions = ObjectRemover.regions(of: mask, extent: extent)
        XCTAssertEqual(regions.count, 2)
        XCTAssertTrue(regions.contains { $0.contains(a) })
        XCTAssertTrue(regions.contains { $0.contains(b) })
        XCTAssertTrue(regions.allSatisfy { extent.contains($0) && $0.width < 200 && $0.height < 200 })
        XCTAssertTrue(ObjectRemover.regions(of: CIImage(color: .black).cropped(to: extent), extent: extent).isEmpty)
    }

    func testGenerativeWindowsRejectEmptyAndOutsideGeometry() {
        let extent = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertTrue(GenerativeInpainter.windows(for: .zero, in: extent).isEmpty)
        XCTAssertTrue(GenerativeInpainter.windows(for: extent, in: .zero).isEmpty)
        XCTAssertTrue(GenerativeInpainter.windows(for: .infinite, in: extent).isEmpty)
        XCTAssertTrue(GenerativeInpainter.windows(for: extent.offsetBy(dx: 900, dy: 0), in: extent).isEmpty)
    }

    /// Um objecto grande vai ao modelo numa só janela com contexto à volta. Em janelas encadeadas que
    /// eram quase só buraco, cada uma via o borrão da anterior e o resultado era uma mancha.
    func testGenerativeRemovalSeesALargeHoleInOneWindowWithContext() {
        let photo = CGRect(x: 0, y: 0, width: 1950, height: 1099)
        let hole = CGRect(x: 150, y: 50, width: 1300, height: 950)
        let windows = GenerativeInpainter.windows(for: hole, in: photo)
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(windows[0].contains(hole), "The whole hole is inside the window")

        let small = CGRect(x: 900, y: 500, width: 100, height: 80)
        let window = GenerativeInpainter.windows(for: small, in: photo)[0]
        XCTAssertTrue(window.contains(small))
        XCTAssertGreaterThanOrEqual(window.width, small.width * 2.5, "There is context on both sides")
        XCTAssertLessThanOrEqual(max(window.width / window.height, window.height / window.width), 2.01)
    }

    /// Um traço fino e comprido é percorrido por várias janelas que o cobrem de ponta a ponta.
    func testGenerativeRemovalWalksALongThinStroke() {
        let photo = CGRect(x: 0, y: 0, width: 1950, height: 1099)
        let stroke = CGRect(x: 780, y: 740, width: 1150, height: 60)
        let windows = GenerativeInpainter.windows(for: stroke, in: photo)
        XCTAssertGreaterThan(windows.count, 1)
        XCTAssertTrue(windows.allSatisfy { photo.contains($0) && $0.minY <= stroke.minY && $0.maxY >= stroke.maxY })
        XCTAssertLessThanOrEqual(windows.map(\.minX).min()!, stroke.minX)
        XCTAssertGreaterThanOrEqual(windows.map(\.maxX).max()!, stroke.maxX)
    }

    /// Com o modelo instalado (`TEST_RUNNER_PPK_GENERATIVE=1`): mexer na exposição depois de uma remoção
    /// não volta a correr o modelo, e o preenchimento acompanha a exposição.
    func testGenerativeRemovalFollowsAdjustmentsWithoutRunningAgain() throws {
        guard ProcessInfo.processInfo.environment["PPK_GENERATIVE"] != nil, GenerativeInpainter.shared.isInstalled
        else { throw XCTSkip("generative off") }
        GenerativeInpainter.shared.isEnabled = true
        let width = 900, height = 600
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in stride(from: 0, to: height, by: 20) {
            ctx.setFillColor(CGColor(srgbRed: 0.3, green: y % 40 == 0 ? 0.45 : 0.35, blue: 0.25, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 20))
        }
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 400, y: 250, width: 100, height: 100))
        let photo = CIImage(cgImage: try XCTUnwrap(ctx.makeImage()))

        var recipe = EditRecipe()
        recipe.removals = [Removal(strokes: [BrushStroke(points: [CurvePoint(x: 450.0 / 900, y: 0.5)], size: 0.2)])]
        let plain = ImageRenderer.shared.apply(recipe, to: photo)
        recipe.exposure = 1
        let started = Date()
        let brighter = ImageRenderer.shared.apply(recipe, to: photo)
        let centre = CGRect(x: 440, y: 290, width: 1, height: 1)
        let p = try pixel(plain.cropped(to: centre)), q = try pixel(brighter.cropped(to: centre))
        _ = ImageRenderer.shared.context.createCGImage(brighter, from: brighter.extent)
        let elapsed = Date().timeIntervalSince(started)
        print("PPK generative render after an adjustment: \(Int(elapsed * 1000)) ms")
        XCTAssertLessThan(p.r, 0.6, "The red disc is gone")
        XCTAssertGreaterThan(q.g, p.g * 1.25, "The fill follows the exposure")
        XCTAssertLessThan(elapsed, 0.35, "The model does not run again for a slider")
    }

    /// Uma pincelada que só apanha a metade de baixo de um nome leva a palavra inteira: com meia letra à
    /// vista, o modelo voltava a desenhá-la.
    func testStrokeOverHalfAWordTakesTheWholeWord() throws {
        let width = 1200, height = 500
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 110, nil)
        let text = NSAttributedString(string: "ASAMOAH", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.95, alpha: 1),
        ])
        ctx.textPosition = CGPoint(x: 200, y: 200)  // linha de base; as letras vão de ~200 a ~280 (origem em baixo)
        CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        let photo = CIImage(cgImage: try XCTUnwrap(ctx.makeImage()))

        // Traço na metade de baixo das letras (y ≈ 215 a contar de baixo), da ponta à ponta da palavra.
        let stroke = CIImage(color: .white).cropped(to: CGRect(x: 210, y: 200, width: 560, height: 30))
            .composited(over: CIImage(color: .black).cropped(to: photo.extent))
        let words = try XCTUnwrap(ObjectRemover.wordsTouched(by: stroke, in: photo), "The word under the stroke is found")
        var top = [Float](repeating: 0, count: 4)
        ImageRenderer.shared.context.render(words, toBitmap: &top, rowBytes: 16, bounds: CGRect(x: 480, y: 270, width: 1, height: 1),
                                            format: .RGBAf, colorSpace: nil)
        XCTAssertGreaterThan(top[0], 0.5, "The tops of the letters, outside the stroke, go too")
        var far = [Float](repeating: 0, count: 4)
        ImageRenderer.shared.context.render(words, toBitmap: &far, rowBytes: 16, bounds: CGRect(x: 480, y: 420, width: 1, height: 1),
                                            format: .RGBAf, colorSpace: nil)
        XCTAssertLessThan(far[0], 0.1, "Nothing away from the word")
    }

    /// Um preenchimento liso (como o da LaMa ampliado numa exportação) ganha o detalhe fino da foto à volta.
    func testGenerativeDetailBringsBackFineTexture() throws {
        let width = 480, height = 320
        var rng = SplitMix64Test(state: 7)
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            let v = 0.3 + Float(rng.next() % 1000) / 1000 * 0.4
            rgba[i * 4] = v; rgba[i * 4 + 1] = v; rgba[i * 4 + 2] = v
        }
        let reference = CIImage(bitmapData: rgba.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16,
                                size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
        let hole = CGRect(x: 160, y: 110, width: 160, height: 100)
        let mask = CIImage(color: .white).cropped(to: hole)
            .composited(over: CIImage(color: .black).cropped(to: reference.extent))
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: hole).composited(over: reference)
        let sharp = try XCTUnwrap(GenerativeDetail.sharpen(flat, reference: reference, mask: mask, bounds: hole, modelScale: 0.25))

        func fineEnergy(_ image: CIImage, in rect: CGRect) -> Float {
            var px = [Float](repeating: 0, count: Int(rect.width * rect.height) * 4)
            ImageRenderer.shared.context.render(image, toBitmap: &px, rowBytes: Int(rect.width) * 16, bounds: rect,
                                                format: .RGBAf, colorSpace: nil)
            let w = Int(rect.width), h = Int(rect.height)
            var total: Float = 0
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let l = 4 * px[(y * w + x) * 4] - px[(y * w + x - 1) * 4] - px[(y * w + x + 1) * 4]
                        - px[((y - 1) * w + x) * 4] - px[((y + 1) * w + x) * 4]
                    total += l * l
                }
            }
            return total / Float((w - 2) * (h - 2))
        }
        let inside = fineEnergy(sharp, in: hole.insetBy(dx: 12, dy: 12))
        let around = fineEnergy(reference, in: CGRect(x: 10, y: 10, width: 120, height: 80))
        XCTAssertGreaterThan(inside, around * 0.3, "The fill carries real fine texture, not a flat patch")
        // Mesmo à resolução da foto a LaMa entrega menos detalhe do que a foto tinha: o refinamento corre.
        XCTAssertNotNil(GenerativeDetail.sharpen(flat, reference: reference, mask: mask, bounds: hole, modelScale: 1))
        GenerativeInpainter.Tuning.detail = false
        defer { GenerativeInpainter.Tuning.detail = true }
        XCTAssertNil(GenerativeDetail.sharpen(flat, reference: reference, mask: mask, bounds: hole, modelScale: 0.25))
    }

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
