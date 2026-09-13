import XCTest
@testable import PhotographersPocketKnife

@MainActor
final class AppStateTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "AppStateTests")
        defaults.removePersistentDomain(forName: "AppStateTests")
    }

    func testDefaultsAreDarkAndPortuguese() {
        let state = AppState(defaults: defaults)
        XCTAssertEqual(state.theme, .dark)
        XCTAssertEqual(state.language, .pt)
    }

    func testThemeAndLanguagePersist() {
        let state = AppState(defaults: defaults)
        state.theme = .light
        state.language = .en
        let reloaded = AppState(defaults: defaults)
        XCTAssertEqual(reloaded.theme, .light)
        XCTAssertEqual(reloaded.language, .en)
    }

    func testLanguageSwitchesAtRuntime() {
        let state = AppState(defaults: defaults)
        XCTAssertEqual(state.t("module.editing"), "Edição")
        state.language = .en
        XCTAssertEqual(state.t("module.editing"), "Editing")
    }

    func testBothLanguagesHaveSameKeys() throws {
        func keys(_ lang: AppLanguage) throws -> Set<String> {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: lang.rawValue))
            let dict = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
            return Set(dict.keys)
        }
        XCTAssertEqual(try keys(.pt), try keys(.en))
    }
}
