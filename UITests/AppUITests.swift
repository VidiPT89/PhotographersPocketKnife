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

    func testEditorZoomsFromTheToolbarAndKeyboard() {
        app.launchArguments += ["-ppk-skip-splash", "-ppk-ui-fixtures"]
        app.launch()
        let editing = app.buttons["Editing"]
        XCTAssertTrue(editing.waitForExistence(timeout: Self.launchTimeout))
        editing.click()
        let fit = app.buttons["Fit photo to window"]
        XCTAssertTrue(fit.waitForExistence(timeout: 10), "Zoom controls in the editor toolbar")
        XCTAssertTrue(app.buttons["Zoom in"].isEnabled)
        XCTAssertFalse(app.buttons["Zoom out"].isEnabled, "Nothing to zoom out of at fit")
        app.buttons["Zoom in"].click()
        XCTAssertTrue(hasValue(fit, "150 %"), "Zoom level after zooming in")
        app.typeKey("=", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Zoom out"].isEnabled)
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(hasValue(fit, "100 %"), "Back to fit")
        XCTAssertFalse(app.buttons["Zoom out"].isEnabled)
    }

    func testFileInfoAssistantTurnsNotesIntoTheCaption() {
        app.launchArguments += ["-ppk-skip-splash", "-ppk-ui-fixtures"]
        app.launch()
        XCTAssertTrue(app.buttons["Culling"].waitForExistence(timeout: Self.launchTimeout))
        app.typeKey("i", modifierFlags: .command)
        let notes = app.textFields["fileinfo-notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10), "Assistant in the file info window")
        XCTAssertTrue(app.buttons["fileinfo-dictate"].exists)
        notes.click()
        notes.typeText("Benfica v Porto at the Estadio da Luz")
        // Sem Apple Intelligence aparece "Usar como legenda"; com ela, "Preencher com IA" (o modelo testa-se nos testes unitários).
        let useCaption = app.buttons["fileinfo-use-caption"]
        guard useCaption.exists else {
            XCTAssertTrue(app.buttons["fileinfo-ai"].isEnabled)
            return
        }
        useCaption.click()
        let caption = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", "Estadio da Luz")).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 3) || app.textFields.containing(NSPredicate(format: "value CONTAINS %@", "Estadio da Luz")).count > 1)
    }

    /// Espera que o valor de acessibilidade do elemento chegue ao esperado.
    private func hasValue(_ element: XCUIElement, _ value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }
}
