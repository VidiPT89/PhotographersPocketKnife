import XCTest
import SwiftUI
@testable import PhotographersPocketKnife

final class MobileZoomTests: XCTestCase {
    func testOffsetsStayWithinViewportAndFitRecentres() {
        let size = CGSize(width: 300, height: 200)
        XCTAssertEqual(MobileZoomPosition().offset(in: size), .zero)
        XCTAssertEqual(MobileZoomPosition(scale: 3, x: -10, y: 10).offset(in: size), CGPoint(x: 0, y: 400))
        XCTAssertEqual(MobileZoomPosition(scale: 2).offset(in: size), CGPoint(x: 150, y: 100))
    }

    @MainActor func testResizePreservesZoomAndRelativePosition() {
        let controller = MobileZoomController(rootView: Color.red)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        controller.viewDidLayoutSubviews()
        let position = MobileZoomPosition(scale: 3, x: 0.6, y: 0.4)
        controller.apply(position)
        XCTAssertEqual(controller.scroll.zoomScale, 3)
        XCTAssertEqual(controller.scroll.contentOffset.x, 390, accuracy: 0.01)
        controller.view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        controller.viewDidLayoutSubviews()
        XCTAssertEqual(controller.scroll.zoomScale, 3)
        XCTAssertEqual(controller.scroll.contentOffset.x, 780, accuracy: 0.01)
        XCTAssertEqual(controller.scroll.contentOffset.y, 280, accuracy: 0.01)
        controller.apply(MobileZoomPosition())
        XCTAssertEqual(controller.scroll.zoomScale, 1)
        XCTAssertEqual(controller.scroll.contentOffset, .zero)
    }

    @MainActor func testSynchronizedViewportDoesNotPublishFeedback() {
        let controller = MobileZoomController(rootView: Color.red)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        controller.viewDidLayoutSubviews()
        var published = 0
        controller.onChange = { _ in published += 1 }
        controller.apply(MobileZoomPosition(scale: 4, x: 0.7, y: 0.3))
        XCTAssertEqual(published, 0)
        XCTAssertEqual(controller.scroll.zoomScale, 4)
    }
}
