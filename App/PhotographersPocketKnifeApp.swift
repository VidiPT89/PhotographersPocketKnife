import SwiftUI
import SwiftData

@main
struct PhotographersPocketKnifeApp: App {
    @State private var appState = AppState()
    private let container: ModelContainer

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
                .onAppear { appState.transfers.attach(context: container.mainContext) }
        }
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(app: appState) }

        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(container)
                .preferredColorScheme(appState.theme.colorScheme)
                .tint(Brand.orange)
        }
    }
}

struct AppCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(app.t("culling.import")) { FilePanels.chooseImportFolder(app) }
                .keyboardShortcut("i")
            Button(app.t("export.title")) {
                app.module = .editing
                NotificationCenter.default.post(name: .showExport, object: nil)
            }
            .keyboardShortcut("e")
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
