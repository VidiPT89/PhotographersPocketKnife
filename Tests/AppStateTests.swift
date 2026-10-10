import XCTest
@testable import PhotographersPocketKnife

@MainActor
final class AppStateTests: XCTestCase {
    // O XCTest cria as instâncias todas antes de correr os testes: limpar só ao criar deixava
    // o idioma de um teste passar para o seguinte. Por isso limpa-se antes de cada teste.
    private let defaults = UserDefaults(suiteName: "AppStateTests")!

    override func setUp() {
        super.setUp()
        defaults.removePersistentDomain(forName: "AppStateTests")
    }

    func testDefaultsAreDarkAndEnglish() {
        let state = AppState(defaults: defaults)
        XCTAssertEqual(state.theme, .dark)
        XCTAssertEqual(state.language, .en)
    }

    func testThemeAndLanguagePersist() {
        let state = AppState(defaults: defaults)
        state.theme = .light
        state.language = .pt
        let reloaded = AppState(defaults: defaults)
        XCTAssertEqual(reloaded.theme, .light)
        XCTAssertEqual(reloaded.language, .pt)
    }

    func testCountsUseTheSingularForOne() {
        let state = AppState(defaults: defaults)
        XCTAssertEqual(state.t("status.selected", count: 1), "1 photo selected")
        XCTAssertEqual(state.t("status.selected", count: 3), "3 photos selected")
        XCTAssertEqual(state.t("status.selected", count: 0), "0 photos selected")
        state.language = .pt
        XCTAssertEqual(state.t("toast.exported", count: 1), "1 foto exportada")
        XCTAssertEqual(state.t("toast.exported", count: 2), "2 fotos exportadas")
    }

    func testLanguageSwitchesAtRuntime() {
        let state = AppState(defaults: defaults)
        XCTAssertEqual(state.t("module.editing"), "Editing")
        state.language = .pt
        XCTAssertEqual(state.t("module.editing"), "Edição")
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
