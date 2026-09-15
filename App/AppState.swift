import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }

    var labelKey: String { "theme.\(rawValue)" }

    var icon: String {
        switch self {
        case .dark: "moon.fill"
        case .light: "sun.max.fill"
        case .system: "circle.lefthalf.filled"
        }
    }
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let icon: String
    let message: String
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case pt = "pt-PT"
    case en = "en"
    var id: String { rawValue }

    var shortLabel: String { self == .pt ? "PT" : "EN" }
}

enum AppModule: String, CaseIterable, Identifiable {
    case culling, editing, upload
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .culling: "square.grid.3x3"
        case .editing: "slider.horizontal.3"
        case .upload: "arrow.up.to.line"
        }
    }

    var labelKey: String { "module.\(rawValue)" }
}

@Observable
@MainActor
final class AppState {
    private let defaults: UserDefaults

    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
            bundle = Self.bundle(for: language)
        }
    }

    var module: AppModule {
        didSet { defaults.set(module.rawValue, forKey: Keys.module) }
    }
    var isSplashVisible = !ProcessInfo.processInfo.arguments.contains("-ppk-skip-splash")
    var showDiagnostics = false
    /// Ficheiros à espera de escolher destino no módulo de envio.
    var pendingUploadURLs: [URL] = []
    /// Pedido de exportação vindo do menu: `false` = exportar, `true` = exportar e enviar.
    var pendingExport: Bool?
    private(set) var toast: Toast?

    let culling = CullingModel()
    let editing = EditingModel()
    let transfers = TransferQueue()
    let hotFolder = HotFolderService()
    let watchFolder = WatchFolderService()
    let denoise = DenoiseQueue()
    let shortcuts: ShortcutStore

    private var bundle: Bundle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Dark é o default: ambiente de trabalho do fotógrafo.
        theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .dark
        let lang = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .pt
        language = lang
        module = AppModule(rawValue: defaults.string(forKey: Keys.module) ?? "") ?? .culling
        bundle = Self.bundle(for: lang)
        shortcuts = ShortcutStore(defaults: defaults)
        transfers.localize = { [weak self] key in self?.t(key) ?? key }
        transfers.onBatchFinished = { [weak self] done, failed in
            guard let self else { return }
            showToast(String(format: t("toast.uploadDone"), done, failed), icon: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        }
        watchFolder.onImported = { [weak self] count in
            guard let self else { return }
            showToast(String(format: t("watch.imported"), count), icon: "eye.fill")
        }
        denoise.onFinished = { [weak self] done, failed in
            guard let self else { return }
            showToast(String(format: t("denoise.finished"), done, failed), icon: failed == 0 ? "sparkles" : "exclamationmark.triangle.fill")
        }
    }

    /// Mostra uma confirmação curta que desaparece sozinha.
    func showToast(_ message: String, icon: String = "checkmark.circle.fill") {
        let next = Toast(icon: icon, message: message)
        toast = next
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if toast?.id == next.id { toast = nil }
        }
    }

    /// Traduz uma chave no idioma escolhido, sem depender do idioma do sistema.
    func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func bundle(for language: AppLanguage, in base: Bundle = .main) -> Bundle {
        guard let path = base.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return base }
        return bundle
    }

    private enum Keys {
        static let theme = "app.theme"
        static let language = "app.language"
        static let module = "app.module"
    }
}
