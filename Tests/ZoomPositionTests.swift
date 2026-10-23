import XCTest
@testable import PhotographersPocketKnife

final class ZoomPositionTests: XCTestCase {
    private let size = CGSize(width: 400, height: 300)

    func testZoomKeepsThePointUnderTheCursorInPlace() {
        let anchor = CGPoint(x: 100, y: 75)
        let zoomed = ZoomPosition().zoomed(to: 2, around: anchor, in: size)
        XCTAssertEqual(zoomed.scale, 2)
        // O ponto (100, 75) da foto, a 2×, fica em (200, 150): o deslocamento põe-no outra vez debaixo do cursor.
        XCTAssertEqual(zoomed.offset(in: size), CGPoint(x: 100, y: 75))
        let again = zoomed.zoomed(to: 4, around: anchor, in: size)
        XCTAssertEqual(again.offset(in: size), CGPoint(x: 300, y: 225))
    }

    func testZoomIsLimitedAndFittingRecentres() {
        XCTAssertEqual(ZoomPosition().zoomed(to: 20, around: .zero, in: size).scale, ZoomPosition.maxScale)
        XCTAssertEqual(ZoomPosition(scale: 3, x: 0.2, y: 0.8).zoomed(to: 0.5, around: .zero, in: size), ZoomPosition())
        XCTAssertEqual(ZoomPosition(scale: 3, x: 0.2, y: 0.8).stepped(0), ZoomPosition())
        XCTAssertEqual(ZoomPosition(scale: 1.2).stepped(1 / 1.5), ZoomPosition())
    }

    func testSteppingKeepsTheCentreWithinTheEdges() {
        let stepped = ZoomPosition(scale: 4, x: 0.9, y: 0.5).stepped(1 / 2)
        XCTAssertEqual(stepped.scale, 2)
        XCTAssertEqual(stepped.x, 0.75)
        XCTAssertEqual(stepped.offset(in: size), CGPoint(x: 400, y: 150))
    }

    func testPanStopsAtThePhotographEdges() {
        let position = ZoomPosition(scale: 2)
        XCTAssertEqual(position.panned(by: CGSize(width: 50, height: -30), in: size).offset(in: size), CGPoint(x: 150, y: 180))
        XCTAssertEqual(position.panned(by: CGSize(width: 1000, height: -1000), in: size).offset(in: size), CGPoint(x: 0, y: 300))
        XCTAssertEqual(ZoomPosition().panned(by: CGSize(width: 50, height: 50), in: size), ZoomPosition())
    }

    func testPreviewDetailFollowsTheZoom() {
        let large: UInt64 = 16 << 30, small: UInt64 = 4 << 30
        XCTAssertEqual(ZoomPosition().previewDetail(physicalMemory: large), 1)
        XCTAssertEqual(ZoomPosition(scale: 2).previewDetail(physicalMemory: large), 2)
        XCTAssertEqual(ZoomPosition(scale: 4).previewDetail(physicalMemory: large), 3)
        XCTAssertEqual(ZoomPosition(scale: 4).previewDetail(physicalMemory: small), 2)
    }
}
