import XCTest

/// Fluxo real da interface: splash com créditos, troca de módulo, idioma e tema.
/// A app corre com `-ppk-ui-testing` (preferências próprias e catálogo em memória).
@MainActor
final class AppUITests: XCTestCase {
    private var app: XCUIApplication!
    /// A primeira abertura depois de compilar passa pela verificação da assinatura e pode demorar muito mais.
    private static let launchTimeout: TimeInterval = 60

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
        // Consoante a versão do macOS, o texto do SwiftUI chega à acessibilidade como `label` ou como `value`.
        let credit = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                                                            "David Arsénio Martins", "David Arsénio Martins")).firstMatch
        XCTAssertTrue(credit.waitForExistence(timeout: Self.launchTimeout), "Developer credit on the splash")
        // Os links entram um instante depois do crédito: espera-se por eles em vez de os ver logo.
        XCTAssertTrue(app.links["ividi.dev"].waitForExistence(timeout: 3) || app.buttons["ividi.dev"].exists
                      || app.staticTexts["ividi.dev"].exists)
        XCTAssertTrue(app.buttons["Culling"].waitForExistence(timeout: 10), "Main window after the splash")
    }

    func testModulesSwitchAndSettingsChangeLanguageAndTheme() {
        app.launchArguments.append("-ppk-skip-splash")
        app.launch()

        let editing = app.buttons["Editing"]
        XCTAssertTrue(editing.waitForExistence(timeout: Self.launchTimeout))
        editing.click()
        XCTAssertTrue(app.staticTexts["No photos to edit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.toolbars.buttons["PT"].exists, "Language lives in Settings, not in the toolbar")

        app.typeKey(",", modifierFlags: .command)
        // As Definições abrem no último separador usado, que o macOS guarda fora das preferências de teste.
        let general = app.windows["com_apple_SwiftUI_Settings_window"].toolbars.buttons["General"]
        if general.waitForExistence(timeout: 5) { general.click() }
        let portuguese = app.radioButtons["PT"]
        XCTAssertTrue(portuguese.waitForExistence(timeout: 5), "Settings window with the language picker")
        portuguese.click()
        XCTAssertTrue(app.buttons["Edição"].waitForExistence(timeout: 5), "Language switches without restarting")

        app.radioButtons["Claro"].click()
        app.radioButtons["Escuro"].click()
        app.radioButtons["EN"].click()
        XCTAssertTrue(app.buttons["Editing"].waitForExistence(timeout: 5))
    }
}
