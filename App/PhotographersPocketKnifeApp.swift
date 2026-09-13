import SwiftUI
import SwiftData
import Sparkle

@main
struct PhotographersPocketKnifeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    private let container: ModelContainer
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    init() {
        do {
            container = try ModelContainer(for: Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self)
        } catch {
            fatalError("Catalog unavailable: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .modelContainer(container)
                .preferredColorScheme(appState.theme.colorScheme)
                .tint(Brand.orange)
                .frame(minWidth: 1100, minHeight: 680)
                .onAppear {
                    appState.transfers.attach(context: container.mainContext)
                    appState.hotFolder.attach(context: container.mainContext)
                    appDelegate.attach { urls in openFromFinder(urls) }
                }
        }
        .handlesExternalEvents(matching: [])
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(app: appState, updater: updater.updater) }

        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(container)
                .preferredColorScheme(appState.theme.colorScheme)
                .tint(Brand.orange)
        }
    }

    /// Pastas ou fotos abertas pelo Finder ("Abrir com") ou largadas no ícone da Dock são importadas no sítio.
    @MainActor
    private func openFromFinder(_ urls: [URL]) {
        let context = container.mainContext
        let culling = appState.culling
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let files = urls.filter { PhotoImporter.isSupported($0) }
        appState.module = .culling
        Task {
            for folder in folders {
                await culling.importFolder(folder, options: .init(copyDestination: nil), session: folder.lastPathComponent, context: context)
            }
            if let first = files.first {
                await culling.importFiles(files, options: .init(copyDestination: nil), session: first.deletingLastPathComponent().lastPathComponent, context: context)
            }
            appState.showToast(String(format: appState.t("toast.imported"), culling.lastImportCount ?? 0), icon: "photo.stack")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handler: (([URL]) -> Void)?
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let handler { handler(urls) } else { pending += urls }
    }

    func attach(_ handler: @escaping ([URL]) -> Void) {
        self.handler = handler
        guard !pending.isEmpty else { return }
        handler(pending)
        pending = []
    }
}

struct AppCommands: Commands {
    let app: AppState
    let updater: SPUUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(app.t("menu.checkUpdates")) { updater.checkForUpdates() }
        }
        CommandGroup(after: .newItem) {
            Button(app.t("culling.import")) { FilePanels.chooseImportFolder(app) }
                .keyboardShortcut("i")
            Button(app.t("export.title")) {
                app.module = .editing
                app.pendingExport = false
            }
            .keyboardShortcut("e")
            Button(app.t("export.andUpload")) {
                app.module = .editing
                app.pendingExport = true
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button(app.t("editing.copy")) {
                app.editing.copySettings()
                app.showToast(app.t("toast.copied"), icon: "doc.on.doc.fill")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(app.module != .editing)
            Button(app.t("editing.paste")) {
                NotificationCenter.default.post(name: .pasteDevelop, object: nil)
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(app.module != .editing || app.editing.clipboard == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(app.t("history.undo")) { app.editing.undo() }
                .keyboardShortcut("z")
                .disabled(app.module != .editing)
            Button(app.t("history.redo")) { app.editing.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(app.module != .editing)
        }
        CommandMenu(app.t("menu.view")) {
            ForEach(Array(AppModule.allCases.enumerated()), id: \.element) { index, module in
                Button(app.t(module.labelKey)) { app.module = module }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
    }
}
