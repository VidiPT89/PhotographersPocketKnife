import SwiftUI

@main
struct PhotographersPocketKnifeApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(appState.theme.colorScheme)
                .tint(Brand.orange)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environment(appState)
                .preferredColorScheme(appState.theme.colorScheme)
                .tint(Brand.orange)
        }
    }
}
