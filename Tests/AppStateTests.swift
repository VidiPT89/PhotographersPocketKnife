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
        XCTAssertEqual(try keys(.pt), try keys(.en))
    }

    /// Chaves geradas a partir de enums não aparecem literalmente no código; confirma que existem.
    func testDynamicKeysAreTranslated() throws {
        let available = try keys(.en)
        let dynamic = AppTheme.allCases.map(\.labelKey) + AppModule.allCases.map(\.labelKey)
            + ColorLabel.allCases.map(\.labelKey) + FlagFilter.allCases.map(\.labelKey) + PhotoSort.allCases.map(\.labelKey)
            + CullingAction.allCases.map(\.labelKey) + EditTab.allCases.map(\.labelKey) + CompareMode.allCases.map(\.labelKey)
            + CropGuide.allCases.map(\.labelKey) + HSLComponent.allCases.map(\.labelKey) + HSLBand.allCases.map(\.labelKey)
            + CurveChannel.allCases.map(\.labelKey) + UploadTab.allCases.map(\.labelKey)
            + MaskKind.allCases.map(\.labelKey) + OutputSharpening.allCases.map(\.labelKey) + MetadataRule.allCases.map(\.labelKey)
            + ResizeMode.allCases.map(\.labelKey) + WatermarkPosition.allCases.map(\.labelKey)
            + Diagnostics.Operation.allCases.map(\.labelKey)
            + AdjustmentSpec.sections.flatMap { [$0.titleKey] + $0.specs.map(\.labelKey) }
        XCTAssertEqual(Set(dynamic).subtracting(available), [])
    }

    func testShortcutsSwapWhenKeyIsTaken() {
        let store = ShortcutStore(defaults: defaults)
        XCTAssertEqual(store.action(for: "P"), .pick)
        store.assign("x", to: .pick)
        XCTAssertEqual(store.action(for: "x"), .pick)
        XCTAssertEqual(store.key(for: .reject), "p")
        XCTAssertEqual(ShortcutStore(defaults: defaults).key(for: .pick), "x", "Persisted")
        store.resetToDefaults()
        XCTAssertEqual(store.key(for: .pick), "p")
    }

    private func keys(_ language: AppLanguage) throws -> Set<String> {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language.rawValue))
        let dict = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
        return Set(dict.keys)
    }
}
