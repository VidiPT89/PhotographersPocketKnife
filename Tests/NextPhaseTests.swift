import XCTest
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import PhotographersPocketKnife

final class NextPhaseTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ppk-next-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Seleção por tipo de trabalho

    func testGenreChangesWhichShotWins() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // Lance nítido com um jogador a piscar os olhos vs. foto mais mole mas com a cara perfeita.
        let action = CullCandidate(id: UUID(), date: start, fileName: "action", rating: 0, flag: .none,
                                   assessment: PhotoAssessment(sharpness: 900, faces: 1, closedEyes: 1, faceQuality: 0.3))
        let face = CullCandidate(id: UUID(), date: start.addingTimeInterval(1), fileName: "face", rating: 0, flag: .none,
                                 assessment: PhotoAssessment(sharpness: 200, faces: 1, faceQuality: 0.95))
        func best(_ genre: CullGenre) -> Set<UUID> {
            var options = CullOptions()
            options.genre = genre
            options.momentGap = genre.momentGap
            return SmartCull.evaluate([action, face], options: options) { _, _ in 0.1 }.best
        }
        XCTAssertEqual(best(.general), [face.id], "Closed eyes rule the frame out in general work")
        XCTAssertEqual(best(.portrait), [face.id])
        XCTAssertEqual(best(.sports), [action.id], "In sports the sharp action wins and blinking is not a flaw")

        var sports = CullOptions()
        sports.genre = .sports
        let report = SmartCull.evaluate([action, face], options: sports) { _, _ in 0.1 }
        XCTAssertNil(report.issues[action.id])
        XCTAssertLessThan(CullGenre.sports.momentGap, CullGenre.landscape.momentGap)
    }

    // MARK: Duplicados exatos

    func testExactDuplicatesNeedTheSameContentNotJustTheSameSize() throws {
        func file(_ name: String, _ bytes: [UInt8]) throws -> ExactDuplicates.Item {
            let url = folder.appendingPathComponent(name)
            try Data(bytes).write(to: url)
            return ExactDuplicates.Item(id: UUID(), url: url, size: Int64(bytes.count))
        }
        let original = try file("IMG_1.JPG", [1, 2, 3, 4])
        let copy = try file("copia/IMG_1 copy.JPG".replacingOccurrences(of: "/", with: "-"), [1, 2, 3, 4])
        let sameSize = try file("IMG_2.JPG", [4, 3, 2, 1])
        let other = try file("IMG_3.JPG", [9, 9])
        let groups = ExactDuplicates.groups([original, copy, sameSize, other])
        XCTAssertEqual(Set(groups.keys), [original.id, copy.id])
        XCTAssertEqual(groups[original.id], groups[copy.id])
    }

    // MARK: GPS

    func testGPSCoordinatesUseSignsForSouthAndWest() throws {
        func props(_ lat: Double, _ latRef: String, _ lon: Double, _ lonRef: String) -> [String: Any] {
            [kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: lat, kCGImagePropertyGPSLatitudeRef as String: latRef,
                kCGImagePropertyGPSLongitude as String: lon, kCGImagePropertyGPSLongitudeRef as String: lonRef,
            ]]
        }
        let cascais = try XCTUnwrap(MetadataReader.coordinate(from: props(38.6979, "N", 9.4215, "W")))
        XCTAssertEqual(cascais.latitude, 38.6979, accuracy: 1e-9)
        XCTAssertEqual(cascais.longitude, -9.4215, accuracy: 1e-9)
        let sydney = try XCTUnwrap(MetadataReader.coordinate(from: props(33.86, "S", 151.2, "E")))
        XCTAssertEqual(sydney.latitude, -33.86, accuracy: 1e-9)
        XCTAssertNil(MetadataReader.coordinate(from: props(0, "N", 0, "E")), "0,0 is what cameras write without a fix")
        XCTAssertNil(MetadataReader.coordinate(from: [:]))
    }

    // MARK: Folha de contactos

    func testContactSheetPaginatesIntoARealPDF() throws {
        XCTAssertEqual(ContactSheet.layout(count: 0, columns: 4).pages, 1)
        let layout = ContactSheet.layout(count: 13, columns: 4)
        XCTAssertEqual(layout.columns, 4)
        let perPage = layout.rowsPerPage * layout.columns
        XCTAssertEqual(layout.pages, (13 + perPage - 1) / perPage)

        let count = perPage + 3
        let items = try (0..<count).map { index -> ContactSheet.Item in
            let url = folder.appendingPathComponent("photo-\(index).png")
            try writePNG(to: url, gray: CGFloat(index % 5) / 5)
            return ContactSheet.Item(url: url, title: url.lastPathComponent, subtitle: "★★★ · Canon EOS R5")
        }
        let pdf = folder.appendingPathComponent("sheet.pdf")
        let pages = try ContactSheet.render(items, title: "Estoril – Benfica", subtitle: "\(count) fotos", to: pdf)
        XCTAssertEqual(pages, 2)
        XCTAssertEqual(CGPDFDocument(pdf as CFURL)?.numberOfPages, 2)
    }

    // MARK: Legendas com jogadores

    func testPlayersCaptionFromShirtNumbersAndRoster() throws {
        XCTAssertEqual(CaptionTemplate.joinNames([], and: " e "), "")
        XCTAssertEqual(CaptionTemplate.joinNames(["Ronaldo"], and: " e "), "Ronaldo")
        XCTAssertEqual(CaptionTemplate.joinNames(["Ronaldo", "Pepe", "Bruno"], and: " e "), "Ronaldo, Pepe e Bruno")
        var context = CaptionTemplate.Context()
        context.players = "Ronaldo e Pepe"
        XCTAssertEqual(CaptionTemplate.resolve("{players} festejam o golo", context), "Ronaldo e Pepe festejam o golo")
        XCTAssertTrue(CaptionTemplate.usesPlayers("Golo de {players}"))

        let roster = CodeReplacements.parse("7\tCristiano Ronaldo\n10\tLionel Messi\n")
        XCTAssertEqual(JerseyNumbers.players(["10", "99", "7"], roster: roster), ["Lionel Messi", "Cristiano Ronaldo"])

        // Um "10" grande numa camisola lisa é lido pelo Vision.
        let width = 900, height = 700
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context2 = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context2.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        context2.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 300, nil)
        let text = NSAttributedString(string: "10", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        context2.textPosition = CGPoint(x: 260, y: 240)
        CTLineDraw(CTLineCreateWithAttributedString(text), context2)
        let image = try XCTUnwrap(context2.makeImage())
        XCTAssertEqual(JerseyNumbers.detect(in: image), ["10"])
    }

    private func writePNG(to url: URL, gray: CGFloat) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
