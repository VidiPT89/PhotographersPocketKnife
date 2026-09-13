import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(app.t("settings.general"), systemImage: "gearshape") }
            ShortcutSettings()
                .tabItem { Label(app.t("settings.shortcuts"), systemImage: "keyboard") }
            UploadSettings()
                .tabItem { Label(app.t("settings.upload"), systemImage: "arrow.up.to.line") }
        }
        .frame(width: 640, height: 480)
    }
}

private struct GeneralSettings: View {
    @Environment(AppState.self) private var app
    @State private var cacheCleared = false

    var body: some View {
        @Bindable var app = app
        Form {
            Picker(app.t("toolbar.language"), selection: $app.language) {
                ForEach(AppLanguage.allCases) { Text($0.shortLabel).tag($0) }
            }
            Picker(app.t("toolbar.theme"), selection: $app.theme) {
                ForEach(AppTheme.allCases) { Text(app.t($0.labelKey)).tag($0) }
            }
            HStack {
                Button(app.t("settings.clearCache")) {
                    ThumbnailCache.shared.clearDisk()
                    cacheCleared = true
                }
                if cacheCleared {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.success)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let shortcuts = app.shortcuts
        Form {
            Section {
                ForEach(CullingAction.allCases) { action in
                    LabeledContent(app.t(action.labelKey)) {
                        TextField("", text: Binding(
                            get: { ShortcutStore.display(shortcuts.key(for: action)) },
                            set: { newValue in
                                guard let last = newValue.last else { return }
                                shortcuts.assign(last == "␣" ? " " : String(last), to: action)
                            }
                        ))
                        .multilineTextAlignment(.center)
                        .frame(width: 44)
                    }
                }
            } footer: {
                Text(app.t("settings.shortcutsHint"))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Button(app.t("settings.resetShortcuts")) { shortcuts.resetToDefaults() }
        }
        .formStyle(.grouped)
    }
}

private struct UploadSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var transfers = app.transfers
        VStack(spacing: 0) {
            Form {
                Stepper("\(app.t("settings.concurrent")): \(transfers.maxConcurrent)", value: $transfers.maxConcurrent, in: 1...6)
                Stepper("\(app.t("settings.retries")): \(transfers.maxAttempts)", value: $transfers.maxAttempts, in: 1...10)
            }
            .formStyle(.grouped)
            .frame(height: 120)
            DestinationsView()
        }
    }
}
