import XCTest
import CoreImage
import ImageIO
@testable import PhotographersPocketKnife

final class SegmentAnythingTests: XCTestCase {

    private func candidate(score: Float, cells: Range<Int>) -> SegmentAnything.Candidate {
        var grid = [Bool](repeating: false, count: 256 * 256)
        for i in cells { grid[i] = true }
        return SegmentAnything.Candidate(mask: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)),
                                         score: score, grid: grid)
    }

    /// A nota do SAM prefere as partes pequenas; para apagar escolhe-se o objecto inteiro.
    func testSelectionTakesTheWholeObjectNotThePartTheModelLikesBest() throws {
        let head = candidate(score: 0.81, cells: 0..<1_000)
        let person = candidate(score: 0.19, cells: 0..<9_000)
        let chosen = try XCTUnwrap(SmartSelection.choose([head, person], piece: nil, onForeground: true))
        XCTAssertEqual(chosen.area, 9_000, "A click on the head takes the person")

        // Uma leitura sem confiança nenhuma não conta, por maior que seja.
        let everything = candidate(score: 0.02, cells: 0..<60_000)
        XCTAssertEqual(SmartSelection.choose([head, person, everything], piece: nil, onForeground: true)?.area, 9_000)
    }

    /// Quando o Vision soltou uma peça que não é gente, vale a leitura que coincide com ela: a maior levava a bota.
    func testSelectionFollowsTheLooseThingVisionFound() throws {
        let ball = candidate(score: 0.76, cells: 0..<2_000)
        let ballAndBoot = candidate(score: 0.83, cells: 0..<3_500)
        var piece = [Bool](repeating: false, count: 256 * 256)
        for i in 0..<1_900 { piece[i] = true }
        XCTAssertEqual(SmartSelection.choose([ballAndBoot, ball], piece: piece, onForeground: true)?.area, 2_000)
    }

    /// Fora do primeiro plano só uma leitura em que o modelo confie: um clique no céu não apaga o céu.
    func testSelectionNeedsConfidenceAwayFromTheForeground() {
        let sky = candidate(score: 0.3, cells: 0..<50_000)
        XCTAssertNil(SmartSelection.choose([sky], piece: nil, onForeground: false))
        let sign = candidate(score: 0.7, cells: 0..<800)
        XCTAssertEqual(SmartSelection.choose([sky, sign], piece: nil, onForeground: false)?.area, 800)
    }

    func testHalfPrecisionDecodes() {
        XCTAssertEqual(SegmentAnything.float(half: 0x3C00), 1)
        XCTAssertEqual(SegmentAnything.float(half: 0xC000), -2)
        XCTAssertEqual(SegmentAnything.float(half: 0x7BFF), 65504)
        XCTAssertEqual(SegmentAnything.float(half: 0x3555), 0.33325195, accuracy: 1e-7)
        XCTAssertEqual(SegmentAnything.float(half: 0x0001), 5.9604645e-8, accuracy: 1e-12)
        XCTAssertEqual(SegmentAnything.float(half: 0x8000), 0)
    }

    /// De ponta a ponta sobre uma foto verdadeira, pelo download real (93 MB), por isso só corre com
    /// `TEST_RUNNER_PPK_SAM=1` e `TEST_RUNNER_PPK_PHOTO` a apontar a foto da jogada.
    func testSegmentAnythingSeparatesPeopleVisionMerges() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PPK_SAM"] != nil, let path = env["PPK_PHOTO"] else { throw XCTSkip("segment anything off") }
        if !SegmentAnything.shared.isInstalled {
            try await SegmentAnything.shared.install { _ in }
        }
        SegmentAnything.shared.isEnabled = true
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let photo = CIImage(cgImage: try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        let e = photo.extent

        func covers(_ mask: CIImage, _ x: Double, _ y: Double) -> Bool {
            var px = [Float](repeating: 0, count: 4)
            ImageRenderer.shared.context.render(mask, toBitmap: &px, rowBytes: 16,
                                                bounds: CGRect(x: e.minX + x * e.width, y: e.maxY - y * e.height, width: 1, height: 1),
                                                format: .RGBAf, colorSpace: nil)
            return px[0] > 0.5
        }
        func share(_ mask: CIImage) -> Double {
            let mean = mask.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: e)])
            var px = [Float](repeating: 0, count: 4)
            ImageRenderer.shared.context.render(mean, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                format: .RGBAf, colorSpace: nil)
            return Double(px[0])
        }

        // Preparada antes, como o painel de remoção faz ao abrir: o primeiro clique já não espera.
        SegmentAnything.shared.prepare(photo)
        _ = SmartSelection.shared.subjectMask(for: photo)
        let started = Date()
        let asamoah = try XCTUnwrap(SmartSelection.shared.objectMask(for: photo, at: CurvePoint(x: 0.12, y: 0.72)))
        let firstClick = Date().timeIntervalSince(started)
        print("PPK SAM first click after preparing: \(Int(firstClick * 1000)) ms")
        XCTAssertLessThan(firstClick, 1.5, "The prepared photo does not make the first click wait")
        let clicked = Date()
        let ronaldo = try XCTUnwrap(SmartSelection.shared.objectMask(for: photo, at: CurvePoint(x: 0.66, y: 0.62)))
        print("PPK SAM next click: \(Int(Date().timeIntervalSince(clicked) * 1000)) ms")
        let ball = try XCTUnwrap(SmartSelection.shared.objectMask(for: photo, at: CurvePoint(x: 0.247, y: 0.09)))

        XCTAssertTrue(covers(asamoah, 0.12, 0.85), "Asamoah's shirt comes with his head")
        XCTAssertFalse(covers(asamoah, 0.66, 0.62), "…and not Ronaldo")
        XCTAssertFalse(covers(ronaldo, 0.12, 0.85), "Ronaldo comes without Asamoah")
        XCTAssertTrue(covers(ball, 0.247, 0.09))
        XCTAssertLessThan(share(ball), 0.03, "The ball alone, not the player kicking it")
        print(String(format: "PPK SAM shares: asamoah %.3f ronaldo %.3f ball %.3f", share(asamoah), share(ronaldo), share(ball)))
    }
}
