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
    @MainActor private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
