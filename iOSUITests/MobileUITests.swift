import XCTest
final class MobileUITests: XCTestCase {
    @MainActor func testCustomPortSurvivesOpeningWithLargeTextAndLightAppearance() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-editing.tab", "basic", "-ppk-ui-testing", "-ppk-light-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
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
        app.launchArguments = ["-editing.tab", "basic", "-ppk-ui-testing"]
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
    @MainActor func testZoomAccumulatesAndResetsForNextPhoto() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-editing.tab", "basic", "-ppk-ui-testing", "-ppk-skip-splash"]
        app.launch()
        let photo = app.buttons["photo-Shoot-01.jpg"]
        XCTAssertTrue(photo.waitForExistence(timeout: 20))
        photo.tap()
        let canvas = app.scrollViews["mobile-zoom"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        func scale() -> Double { Double((canvas.value as? String ?? "0").replacingOccurrences(of: "x", with: "")) ?? 0 }
        canvas.pinch(withScale: 2, velocity: 1)
        let first = scale()
        XCTAssertGreaterThan(first, 1.3)
        canvas.pinch(withScale: 1.5, velocity: 1)
        XCTAssertGreaterThan(scale(), first + 0.2, "A second pinch must continue from the current zoom")
        canvas.swipeLeft()
        XCTAssertGreaterThan(scale(), first)
        screenshot("Editor-Zoom-Pan")
        let beforeZoomOut = scale()
        canvas.pinch(withScale: 0.75, velocity: -1)
        XCTAssertLessThan(scale(), beforeZoomOut)
        XCTAssertGreaterThan(scale(), 1, "Pinching inward should reduce zoom progressively")
        canvas.doubleTap()
        XCTAssertTrue(app.buttons["mobile-fit-photo"].waitForExistence(timeout: 3))
        let reset = NSPredicate(format: "value == %@", "1.00x")
        expectation(for: reset, evaluatedWith: canvas)
        waitForExpectations(timeout: 5)
        canvas.doubleTap()
        let enlarged = NSPredicate { _, _ in scale() > 2 }
        expectation(for: enlarged, evaluatedWith: canvas)
        waitForExpectations(timeout: 5)
        app.buttons["mobile-next-photo"].tap()
        expectation(for: reset, evaluatedWith: app.scrollViews["mobile-zoom"])
        waitForExpectations(timeout: 5)
        screenshot("Editor-Next-Photo-Fit")
        app.buttons["mobile-editing-options"].tap()
        app.buttons["Presentation"].tap()
        let presentation = app.scrollViews["mobile-presentation-zoom"]
        XCTAssertTrue(presentation.waitForExistence(timeout: 5))
        presentation.pinch(withScale: 2, velocity: 1)
        XCTAssertNotEqual(presentation.value as? String, "1.00x")
        presentation.swipeLeft()
        screenshot("Presentation-Zoom")
        app.buttons["Close presentation"].tap()
        XCTAssertTrue(app.buttons["mobile-fit-photo"].waitForExistence(timeout: 5))
    }

    @MainActor func testComparisonSynchronizesZoomAndSurvivesRotation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-editing.tab", "basic", "-ppk-ui-testing", "-ppk-skip-splash"]
        app.launch()
        XCTAssertTrue(app.buttons["photo-Shoot-01.jpg"].waitForExistence(timeout: 20))
        app.buttons["mobile-select"].tap()
        app.buttons["photo-Shoot-01.jpg"].tap()
        app.buttons["photo-Shoot-02.jpg"].tap()
        app.buttons["Tools"].tap()
        app.buttons["Compare"].tap()
        let panes = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mobile-compare-zoom-"))
        XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(panes.count, 2)
        panes.element(boundBy: 0).pinch(withScale: 2, velocity: 1)
        XCTAssertNotEqual(panes.element(boundBy: 0).value as? String, "1.00x")
        XCTAssertEqual(panes.element(boundBy: 0).value as? String, panes.element(boundBy: 1).value as? String)
        panes.element(boundBy: 1).swipeLeft()
        screenshot("Compare-Synchronized-Zoom")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertEqual(panes.element(boundBy: 0).value as? String, panes.element(boundBy: 1).value as? String)
        panes.element(boundBy: 1).doubleTap()
        expectation(for: NSPredicate(format: "value == %@", "1.00x"), evaluatedWith: panes.element(boundBy: 0))
        waitForExpectations(timeout: 5)
        screenshot("Compare-Landscape-Fit")
    }

    @MainActor func testPinchingCropDoesNotCreateAnEdit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-editing.tab", "basic", "-ppk-ui-testing", "-ppk-skip-splash"]
        app.launch()
        XCTAssertTrue(app.buttons["photo-Shoot-01.jpg"].waitForExistence(timeout: 20))
        app.buttons["photo-Shoot-01.jpg"].tap()
        XCTAssertTrue(app.buttons["mobile-editing-tool"].waitForExistence(timeout: 10))
        app.buttons["mobile-editing-tool"].tap()
        app.buttons["Crop & geometry"].tap()
        let canvas = app.scrollViews["mobile-zoom"]
        XCTAssertFalse(app.buttons["Undo"].isEnabled)
        canvas.pinch(withScale: 2, velocity: 1)
        XCTAssertNotEqual(canvas.value as? String, "1.00x")
        XCTAssertFalse(app.buttons["Undo"].isEnabled, "Pinching must not modify the crop")
        app.buttons["mobile-fit-photo"].tap()
        XCTAssertEqual(canvas.value as? String, "1.00x")
        screenshot("Crop-Touch-Controls")
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
        app.launchArguments = ["-editing.tab", "basic", "-ppk-ui-testing", "-ppk-hold-splash"]
        app.launchEnvironment["PPK_DEMO_PHOTOS"] = photos
        app.launch()
        XCTAssertTrue(app.staticTexts["CULL · DEVELOP · DELIVER"].waitForExistence(timeout: 20))
        sleep(2)
        try save("1-Welcome")
        app.terminate()
        app.launchArguments = ["-editing.tab", "basic", "-ppk-ui-testing", "-ppk-skip-splash"]
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
    @MainActor func testFileInfoAssistantTurnsNotesIntoFields() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-editing.tab", "basic", "-ppk-ui-testing", "-ppk-skip-splash"]
        app.launch()
        XCTAssertTrue(app.buttons["photo-Shoot-01.jpg"].waitForExistence(timeout: 20))
        app.buttons["mobile-select"].tap()
        app.buttons["photo-Shoot-01.jpg"].tap()
        app.buttons["Tools"].tap()
        app.buttons["File info"].tap()
        let notes = app.textFields["fileinfo-notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        // Carregar no micro já fechou a app (autorização da fala fora do MainActor); tem de continuar viva.
        addUIInterruptionMonitor(withDescription: "Microphone and speech") { alert in
            for label in ["Allow", "OK", "Permitir"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        let dictate = app.buttons["fileinfo-dictate"]
        XCTAssertTrue(dictate.exists)
        // No simulador o AURemoteIO não chega ao microfone do Mac e aborta; o micro só se testa num iPhone.
        #if !targetEnvironment(simulator)
        dictate.tap()
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground)
        if dictate.label == "Stop" { dictate.tap() }
        sleep(1)
        #endif
        notes.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { notes.tap() }
        notes.typeText("Pavlidis scores in Lisbon")
        let useCaption = app.buttons["fileinfo-use-caption"]
        if useCaption.exists {
            useCaption.tap()
            // Com texto, o campo perde o placeholder "Caption"; procura-se pelo valor (notas + legenda).
            // No iPhone o ditado pode ter apanhado som da sala antes do texto escrito.
            let filled = app.textFields.matching(NSPredicate(format: "value CONTAINS %@", "Pavlidis scores in Lisbon"))
            XCTAssertEqual(filled.count, 2)
        } else {
            let ai = app.buttons["fileinfo-ai"]
            XCTAssertTrue(ai.isEnabled)
            // No simulador o modelo não carrega os recursos de segurança; num iPhone corre a sério, dentro da app.
            #if !targetEnvironment(simulator)
            ai.tap()
            let apply = app.buttons["fileinfo-apply"]
            XCTAssertTrue(apply.waitForExistence(timeout: 90), "The on-device model did not return a proposal")
            let proposal = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            print("AI proposal:", proposal)
            XCTAssertTrue(proposal.contains("Pavlidis"))
            XCTAssertFalse(["Vangelis", "Evangelos", "1-0", "2-1"].contains { proposal.contains($0) },
                           "The model added facts that are not in the notes")
            screenshot("FileInfo-AI-Proposal")
            apply.tap()
            XCTAssertFalse(apply.exists)
            #endif
        }
        screenshot("FileInfo-Assistant")
    }

    @MainActor private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
