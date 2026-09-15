import XCTest
import CoreImage
@testable import PhotographersPocketKnife

final class WorkflowToolsTests: XCTestCase {

    func testCodeReplacementsFollowPhotoMechanicFormat() {
        let codes = CodeReplacements.parse("7\tCristiano Ronaldo\tRonaldo\r\n10\tLionel Messi\t\n\nlinha sem tabulação\nBEN\tSL Benfica\n7\tDuplicado\n")
        XCTAssertEqual(codes.count, 3)
        XCTAssertEqual(codes.apply("=7= marca, =7#2= festeja com =10=; =99= e 2=3 e = 7 ="),
                       "Cristiano Ronaldo marca, Ronaldo festeja com Lionel Messi; =99= e 2=3 e = 7 =")
        XCTAssertEqual(codes.apply("=ben= vence"), "SL Benfica vence", "Codes match regardless of case")
        XCTAssertEqual(codes.apply("=7#5= e =7#x="), "=7#5= e =7#x=", "Missing columns are left as typed")
        XCTAssertEqual(codes.apply("\\10\\ remata", delimiter: "\\"), "Lionel Messi remata")

        var fields = IPTCFields()
        fields.caption = "=7= ({date})"
        fields.keywords = "futebol, =BEN="
        let expanded = codes.apply(to: fields)
        XCTAssertEqual(expanded.caption, "Cristiano Ronaldo ({date})")
        XCTAssertEqual(expanded.keywordList, ["futebol", "SL Benfica"])
        XCTAssertEqual(CodeReplacements().apply("=7="), "=7=")
    }

    func testTimeShiftDescription() {
        XCTAssertEqual(TimeShift.describe(0), "0 s")
        XCTAssertEqual(TimeShift.describe(-45), "−45 s")
        XCTAssertEqual(TimeShift.describe(125), "+2 min 05 s")
        XCTAssertEqual(TimeShift.describe(3725), "+1 h 02 min 05 s")
        XCTAssertEqual(TimeShift.describe(-7200), "−2 h 00 min 00 s")
    }

    func testWatchFolderOnlyTakesNewFilesThatFinishedWriting() {
        let ready = WatchFolderScanner.ready(
            current: ["/in/a.jpg": 100, "/in/b.nef": 50, "/in/c.jpg": 0, "/in/d.jpg": 70, "/in/e.jpg": 30],
            previous: ["/in/a.jpg": 100, "/in/b.nef": 40, "/in/c.jpg": 0, "/in/d.jpg": 70],
            known: ["/in/d.jpg"]
        )
        XCTAssertEqual(ready, ["/in/a.jpg"], "Growing, empty, already catalogued and just-appeared files wait")
    }

    func testWatchFolderScansSupportedFilesWithSizes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 1, count: 12).write(to: folder.appendingPathComponent("sub/IMG_1.JPG"))
        try Data(repeating: 1, count: 5).write(to: folder.appendingPathComponent("notes.txt"))
        let sizes = WatchFolderScanner.sizes(in: folder)
        XCTAssertEqual(sizes.count, 1)
        XCTAssertEqual(sizes.values.first, 12)
    }

    func testFocusPeakingMarksSharpEdgesMoreThanBlurredOnes() throws {
        let width = 400, height = 300
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 10, to: width, by: 24) {
            context.fill(CGRect(x: x, y: 0, width: 10, height: height))
        }
        let sharp = try XCTUnwrap(context.makeImage())
        let blurredCI = CIImage(cgImage: sharp).clampedToExtent().applyingGaussianBlur(sigma: 8).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let blurred = try XCTUnwrap(CIContext().createCGImage(blurredCI, from: blurredCI.extent))

        let sharpOverlay = try XCTUnwrap(FocusPeaking.overlay(for: sharp))
        let blurredOverlay = try XCTUnwrap(FocusPeaking.overlay(for: blurred))
        XCTAssertEqual(sharpOverlay.width, width)
        let sharpCoverage = FocusPeaking.coverage(sharpOverlay)
        let blurredCoverage = FocusPeaking.coverage(blurredOverlay)
        XCTAssertGreaterThan(sharpCoverage, 0.05)
        XCTAssertLessThan(blurredCoverage, sharpCoverage * 0.25, "sharp \(sharpCoverage) blurred \(blurredCoverage)")
    }
}
