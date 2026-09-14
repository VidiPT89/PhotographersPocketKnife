import XCTest

/// Fluxo real da interface: splash com créditos, troca de módulo, idioma e tema.
/// A app corre com `-ppk-ui-testing` (preferências próprias e catálogo em memória).
@MainActor
final class AppUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ppk-ui-testing"]
    }

    override func tearDown() async throws {
        app.terminate()
    }

    func testSplashShowsCreditsThenOpensTheApp() {
        app.launch()
        let credit = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "David Arsénio Martins")).firstMatch
        XCTAssertTrue(credit.waitForExistence(timeout: 5), "Developer credit on the splash")
        XCTAssertTrue(app.links["ividi.dev"].exists || app.buttons["ividi.dev"].exists || app.staticTexts["ividi.dev"].exists)
        XCTAssertTrue(app.buttons["Seleção"].waitForExistence(timeout: 10), "Main window after the splash")
    }

    func testModulesSwitchAndSettingsChangeLanguageAndTheme() {
        app.launchArguments.append("-ppk-skip-splash")
        app.launch()

        let editing = app.buttons["Edição"]
        XCTAssertTrue(editing.waitForExistence(timeout: 10))
        editing.click()
        XCTAssertTrue(app.staticTexts["Nenhuma foto para editar"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.toolbars.buttons["EN"].exists, "Language lives in Settings, not in the toolbar")

        app.typeKey(",", modifierFlags: .command)
        let english = app.radioButtons["EN"]
        XCTAssertTrue(english.waitForExistence(timeout: 5), "Settings window with the language picker")
        english.click()
        XCTAssertTrue(app.buttons["Editing"].waitForExistence(timeout: 5), "Language switches without restarting")

        app.radioButtons["Light"].click()
        app.radioButtons["Dark"].click()
        app.radioButtons["PT"].click()
        XCTAssertTrue(app.buttons["Edição"].waitForExistence(timeout: 5))
    }
}
