import XCTest
final class MobileUITests: XCTestCase {
    @MainActor func testCustomPortSurvivesOpeningWithLargeTextAndLightAppearance() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ppk-ui-testing", "-ppk-light-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["photo-Shoot-01.jpg"].waitForExistence(timeout: 20))
        screenshot("Catalog-Light-LargeText")
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Upload")).firstMatch.tap()
        let destination = app.buttons["destination-Custom port fixture"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        destination.tap()
        let port = app.textFields["Port"]
        XCTAssertTrue(port.waitForExistence(timeout: 5))
        XCTAssertEqual((port.value as? String)?.filter(\.isNumber), "12121")
        screenshot("Destination-Light-LargeText")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
    }

    @MainActor func testCatalogEditorAndLanguageSwitch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ppk-ui-testing"]
        app.launch()
        let photo = app.buttons["photo-Shoot-01.jpg"]
        XCTAssertTrue(photo.waitForExistence(timeout: 20))
        screenshot("Catalog")
        photo.tap()
        XCTAssertTrue(app.navigationBars["Shoot-01.jpg"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["mobile-editing-tool"].exists)
        screenshot("Editor")
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Upload")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Add destination"].waitForExistence(timeout: 5))
        app.buttons["Add destination"].tap()
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 5))
        screenshot("Destination")
        app.buttons["Cancel"].tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Culling")).firstMatch.tap()
        app.buttons["mobile-settings"].tap()
        XCTAssertTrue(app.staticTexts["Photographer's Pocket Knife"].waitForExistence(timeout: 5))
        screenshot("Settings")
        app.buttons["mobile-language"].tap()
        app.buttons["Português (Portugal)"].tap()
        XCTAssertTrue(app.navigationBars["Definições"].waitForExistence(timeout: 5))
        screenshot("Settings-Portuguese")
    }
    /// Capturas para a App Store; só corre com TEST_RUNNER_PPK_SCREENSHOTS e TEST_RUNNER_PPK_DEMO_PHOTOS.
    @MainActor func testAppStoreScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["PPK_SCREENSHOTS"], let photos = environment["PPK_DEMO_PHOTOS"] else {
            throw XCTSkip("App Store screenshots not requested")
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        func save(_ name: String) throws {
            let url = URL(fileURLWithPath: output).appendingPathComponent("\(device)-\(name).png")
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ppk-ui-testing", "-ppk-hold-splash"]
        app.launchEnvironment["PPK_DEMO_PHOTOS"] = photos
        app.launch()
        XCTAssertTrue(app.staticTexts["CULL · DEVELOP · DELIVER"].waitForExistence(timeout: 20))
        sleep(2)
        try save("1-Welcome")
        app.terminate()
        app.launchArguments = ["-ppk-ui-testing", "-ppk-skip-splash"]
        app.launch()
        let first = app.buttons["photo-DSC_4801.jpg"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        sleep(3)
        try save("2-Catalog")
        first.tap()
        XCTAssertTrue(app.buttons["mobile-editing-tool"].waitForExistence(timeout: 15))
        app.buttons["Auto"].firstMatch.tap()
        sleep(4)
        try save("3-Editor")
        app.navigationBars.buttons.firstMatch.tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Upload")).firstMatch.tap()
        let destination = app.buttons["destination-Newsdesk"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        try save("4-Deliver")
        destination.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        sleep(1)
        try save("5-Destination")
    }
    @MainActor private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
