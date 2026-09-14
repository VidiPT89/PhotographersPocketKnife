import XCTest
import SwiftData
import CoreImage
@testable import PhotographersPocketKnife

final class SmartCullTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Decisões

    func testMomentsSplitByTimeAndSimilarity() {
        let scenes = ["a": 0, "b": 0, "c": 1, "d": 1, "e": 1]
        let candidates = [
            candidate("a", seconds: 0), candidate("b", seconds: 2),
            candidate("c", seconds: 4), // outra cena logo a seguir
            candidate("d", seconds: 60), candidate("e", seconds: 62), // mesma cena, muito depois
        ]
        let report = SmartCull.evaluate(candidates, options: CullOptions()) { first, second in
            scenes[first.fileName] == scenes[second.fileName] ? 0.2 : 0.9
        }
        let moment = { (name: String) in report.moments[candidates.first { $0.fileName == name }!.id] }
        XCTAssertEqual(moment("a"), moment("b"))
        XCTAssertNotEqual(moment("b"), moment("c"), "A different scene starts a new moment")
        XCTAssertNotEqual(moment("c"), moment("d"), "A long pause starts a new moment")
        XCTAssertEqual(moment("d"), moment("e"))
        XCTAssertEqual(report.momentCount, 3)
    }

    func testBestShotIsPickedAndFlawedShotsAreRejected() {
        var sharp = PhotoAssessment(sharpness: 520, faces: 1, faceQuality: 0.8)
        sharp.brightness = 0.45
        let eyesClosed = PhotoAssessment(sharpness: 540, faces: 1, closedEyes: 1, faceQuality: 0.85)
        let blurry = PhotoAssessment(sharpness: 4, faces: 1, faceQuality: 0.4)
        let dark = PhotoAssessment(sharpness: 300, brightness: 0.05, clippedShadows: 0.6)
        let candidates = [
            candidate("sharp", seconds: 0, sharp), candidate("closed", seconds: 1, eyesClosed),
            candidate("blurry", seconds: 2, blurry), candidate("dark", seconds: 3, dark),
        ]
        let report = SmartCull.evaluate(candidates, options: CullOptions()) { _, _ in 0.1 }
        XCTAssertEqual(report.momentCount, 1)
        XCTAssertEqual(report.best, [candidates[0].id], "Eyes closed never wins, even when sharper")
        XCTAssertEqual(report.issues[candidates[1].id], [.eyesClosed])
        XCTAssertEqual(report.issues[candidates[2].id], [.blurry])
        XCTAssertEqual(report.issues[candidates[3].id], [.underexposed])

        let decisions = SmartCull.decisions(for: candidates, report: report, options: CullOptions())
        XCTAssertEqual(decisions[candidates[0].id]?.flag, .pick)
        XCTAssertGreaterThanOrEqual(decisions[candidates[0].id]?.rating ?? 0, 2)
        XCTAssertEqual(decisions[candidates[1].id]?.flag, .reject)
        XCTAssertEqual(decisions[candidates[2].id]?.flag, .reject)
        XCTAssertEqual(decisions[candidates[3].id]?.flag, .reject)

        var gentle = CullOptions()
        gentle.rejectProblems = false
        gentle.assignStars = false
        let onlyPicks = SmartCull.decisions(for: candidates, report: report, options: gentle)
        XCTAssertEqual(onlyPicks.count, 1)
        XCTAssertEqual(onlyPicks[candidates[0].id], CullDecision(rating: 0, flag: .pick))
    }

    func testBlurIsJudgedAgainstTheRestOfTheShoot() {
        // Numa sessão nítida, uma foto bastante mais mole que as outras é desfocada; numa sessão mole, não.
        let crisp = (0..<5).map { candidate("crisp\($0)", seconds: Double($0) * 30, PhotoAssessment(sharpness: 900)) }
        let soft = candidate("soft", seconds: 400, PhotoAssessment(sharpness: 40))
        let crispReport = SmartCull.evaluate(crisp + [soft], options: CullOptions()) { _, _ in nil }
        XCTAssertEqual(crispReport.issues[soft.id], [.blurry])

        let allSoft = (0..<5).map { candidate("soft\($0)", seconds: Double($0) * 30, PhotoAssessment(sharpness: 45)) }
        let softReport = SmartCull.evaluate(allSoft + [soft], options: CullOptions()) { _, _ in nil }
        XCTAssertNil(softReport.issues[soft.id])
    }

    @MainActor
    func testAutomaticCullRespectsManualRatingsAndCanBeUndone() async throws {
        let container = try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        func photo(_ name: String, seconds: Double, _ assessment: PhotoAssessment, rating: Int = 0) -> Photo {
            let info = ImportedPhotoInfo(url: URL(fileURLWithPath: "/tmp/\(name).jpg"), captureDate: start.addingTimeInterval(seconds),
                                         camera: nil, lens: nil, width: 10, height: 10, fileSize: 1)
            let photo = Photo(info: info, sessionName: "Jogo")
            photo.assessmentData = try? JSONEncoder().encode(assessment)
            photo.rating = rating
            container.mainContext.insert(photo)
            return photo
        }
        let best = photo("best", seconds: 0, PhotoAssessment(sharpness: 700))
        let blurry = photo("blurry", seconds: 1, PhotoAssessment(sharpness: 5))
        let manual = photo("manual", seconds: 2, PhotoAssessment(sharpness: 6), rating: 3)
        let photos = [best, blurry, manual]

        let model = CullingModel()
        await model.analyze(photos, options: CullOptions())
        XCTAssertEqual(model.analysisDone, 3, "Stored assessments are reused, nothing to analyse again")
        XCTAssertEqual(model.cullBadge(for: best.id)?.isBest, true)
        XCTAssertTrue(model.showCullBadges)

        let result = model.applyAutomatic(to: photos, options: CullOptions())
        XCTAssertEqual(result.picks, 1)
        XCTAssertEqual(result.rejects, 1)
        XCTAssertEqual(best.flag, .pick)
        XCTAssertGreaterThan(best.rating, 0)
        XCTAssertEqual(blurry.flag, .reject)
        XCTAssertEqual(manual.rating, 3, "What I rated by hand stays")
        XCTAssertEqual(manual.flag, .none)

        model.sort = .score
        model.sortAscending = false
        XCTAssertEqual(model.visible(photos).first?.id, best.id)
        model.showIssuesOnly = true
        XCTAssertFalse(model.visible(photos).contains { $0.id == best.id })

        model.undoAutomaticCull(in: photos)
        XCTAssertEqual(best.flag, .none)
        XCTAssertEqual(best.rating, 0)
        XCTAssertEqual(blurry.flag, .none)
        XCTAssertFalse(model.canUndoAutomaticCull)
    }

    // MARK: Análise com o Vision

    func testAssessorMeasuresSharpnessExposureAndSimilarity() async throws {
        let sharpImage = try checkerboard(brightness: 1)
        let blurredImage = try blurred(sharpImage)
        let darkImage = try checkerboard(brightness: 0.04)

        let sharp = await PhotoAssessor.assess(sharpImage)
        let soft = await PhotoAssessor.assess(blurredImage)
        let dark = await PhotoAssessor.assess(darkImage)
        XCTAssertGreaterThan(sharp.sharpness, soft.sharpness * 4, "Blur lowers the measured sharpness")
        XCTAssertLessThan(dark.brightness, 0.1)
        XCTAssertGreaterThan(sharp.brightness, dark.brightness)
        XCTAssertNotNil(sharp.featurePrint)
        XCTAssertEqual(try JSONDecoder().decode(PhotoAssessment.self, from: JSONEncoder().encode(sharp)), sharp)

        let other = await PhotoAssessor.assess(try stripes())
        let distances = FeaturePrintDistances()
        let a = candidate("a", seconds: 0, sharp), b = candidate("b", seconds: 1, soft), c = candidate("c", seconds: 2, other)
        let sameScene = try XCTUnwrap(distances.distance(a, b))
        let otherScene = try XCTUnwrap(distances.distance(a, c))
        XCTAssertLessThan(sameScene, otherScene, "The blurred copy is closer than a different picture")
    }

    /// `TEST_RUNNER_PPK_CULL_DIR=/pasta/com/fotos` mostra a análise de uma sessão verdadeira.
    func testRealShootReport() async throws {
        guard let path = ProcessInfo.processInfo.environment["PPK_CULL_DIR"] else { throw XCTSkip("No real shoot configured") }
        let files = PhotoImporter.imageFiles(in: URL(fileURLWithPath: path))
        var candidates: [CullCandidate] = []
        let started = Date()
        for file in files {
            guard let assessment = await PhotoAssessor.assess(url: file) else { continue }
            let info = MetadataReader.basicInfo(for: file)
            candidates.append(CullCandidate(id: UUID(), date: info.captureDate, fileName: file.lastPathComponent, rating: 0, flag: .none, assessment: assessment))
        }
        print("PPK analysed", candidates.count, "photos in", String(format: "%.1f s", Date().timeIntervalSince(started)))
        let report = SmartCull.evaluate(candidates, options: CullOptions(), distance: FeaturePrintDistances().distance)
        for c in candidates.sorted(by: { (report.moments[$0.id] ?? 0, $0.fileName) < (report.moments[$1.id] ?? 0, $1.fileName) }) {
            let a = c.assessment
            print(String(format: "PPK m%02d %@ %3.0f sharp=%6.0f faces=%d closed=%d q=%.2f aes=%@ %@ %@",
                         report.moments[c.id] ?? 0, c.fileName, (report.scores[c.id] ?? 0) * 100, a.sharpness, a.faces, a.closedEyes,
                         a.faceQuality ?? -1, a.aesthetics.map { String(format: "%.2f", $0) } ?? "-",
                         report.best.contains(c.id) ? "BEST" : "", (report.issues[c.id] ?? []).map(\.rawValue).joined(separator: ",")))
        }
    }

    // MARK: Utilitários

    private func candidate(_ name: String, seconds: Double, _ assessment: PhotoAssessment = PhotoAssessment(sharpness: 400)) -> CullCandidate {
        CullCandidate(id: UUID(), date: start.addingTimeInterval(seconds), fileName: name, rating: 0, flag: .none, assessment: assessment)
    }

    private func checkerboard(brightness: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<24 {
            for x in 0..<32 {
                let light = (x + y) % 2 == 0
                context.setFillColor(CGColor(red: (light ? 0.9 : 0.15) * brightness, green: (light ? 0.8 : 0.2) * brightness, blue: (light ? 0.6 : 0.3) * brightness, alpha: 1))
                context.fill(CGRect(x: x * 20, y: y * 20, width: 20, height: 20))
            }
        }
        context.setFillColor(CGColor(red: 0.95 * brightness, green: 0.4 * brightness, blue: 0.05, alpha: 1))
        context.fillEllipse(in: CGRect(x: 220, y: 140, width: 200, height: 200))
        return try XCTUnwrap(context.makeImage())
    }

    private func stripes() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for x in stride(from: 0, to: 640, by: 60) {
            context.fill(CGRect(x: x, y: 0, width: 12, height: 480))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func blurred(_ image: CGImage) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: input.extent)
        return try XCTUnwrap(ImageRenderer.shared.context.createCGImage(output, from: input.extent))
    }
}
