import SwiftUI
import SwiftData

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
            HotFolderSettings()
                .tabItem { Label(app.t("hotFolder.title"), systemImage: "flame") }
            WatchFolderSettings()
                .tabItem { Label(app.t("watch.title"), systemImage: "eye") }
        }
        .frame(width: 680, height: 480)
    }
}

private struct WatchFolderSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var watch = app.watchFolder
        Form {
            Section {
                Toggle(app.t("watch.enable"), isOn: $watch.isEnabled)
                    .disabled(watch.folderPath.isEmpty)
                Text(app.t("watch.hint"))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Section {
                LabeledContent(app.t("watch.folder")) {
                    HStack {
                        Text(watch.folderPath.isEmpty ? "—" : watch.folderPath).lineLimit(1).truncationMode(.middle)
                        Button(app.t("common.choose")) {
                            if let url = FilePanels.chooseFolder(prompt: app.t("common.choose")) { watch.folderPath = url.path }
                        }
                    }
                }
                TextField(app.t("watch.session"), text: $watch.sessionName)
                if watch.isEnabled {
                    Label(String(format: app.t("watch.status"), watch.importedCount), systemImage: "eye.fill")
                        .foregroundStyle(Brand.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotFolderSettings: View {
    @Environment(AppState.self) private var app
    @Query(sort: \UploadDestination.name) private var destinations: [UploadDestination]

    var body: some View {
        @Bindable var hot = app.hotFolder
        Form {
            Section {
                Toggle(app.t("hotFolder.enable"), isOn: $hot.isEnabled)
                Text(app.t("hotFolder.hint"))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Section {
                Picker(app.t("hotFolder.label"), selection: $hot.label) {
                    ForEach(ColorLabel.allCases.dropFirst()) { label in
                        Text(app.t(label.labelKey)).tag(label)
                    }
                }
                Picker(app.t("upload.destination"), selection: $hot.destinationID) {
                    Text("—").tag(UUID?.none)
                    ForEach(destinations) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField(app.t("rename.event"), text: $hot.event)
                LabeledContent(app.t("hotFolder.exportFolder")) {
                    HStack {
                        Text(hot.exportFolder.path).lineLimit(1).truncationMode(.middle)
                        Button(app.t("common.choose")) {
                            if let url = FilePanels.chooseFolder(prompt: app.t("common.choose")) { hot.exportFolderPath = url.path }
                        }
                    }
                }
            } footer: {
                Text(app.t("hotFolder.settingsHint"))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .formStyle(.grouped)
        .disabled(false)
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
            .pickerStyle(.segmented)
            Picker(app.t("toolbar.theme"), selection: $app.theme) {
                ForEach(AppTheme.allCases) { Label(app.t($0.labelKey), systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Button(app.t("settings.clearCache")) {
                    ThumbnailCache.shared.clearDisk()
                    cacheCleared = true
                }
                if cacheCleared {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Brand.success)
                        .accessibilityLabel(app.t("settings.cacheCleared"))
                }
            }
            GenerativeModelRow()
        }
        .formStyle(.grouped)
    }
}

/// Instalar ou remover o modelo que inventa o que estava por baixo do que se apaga.
private struct GenerativeModelRow: View {
    @Environment(AppState.self) private var app
    @State private var installed = GenerativeInpainter.shared.isInstalled
    @State private var enabled = GenerativeInpainter.shared.isEnabled
    @State private var progress: Double?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.t("settings.generativeModel"))
                    Text(app.t(installed ? "settings.generativeInstalled" : "settings.generativeHint"))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                if let progress {
                    ProgressView(value: progress).frame(width: 120)
                } else if installed {
                    Toggle("", isOn: $enabled)
                        .labelsHidden()
                        .onChange(of: enabled) { _, value in GenerativeInpainter.shared.isEnabled = value }
                    Button(app.t("settings.generativeRemove"), role: .destructive) {
                        GenerativeInpainter.shared.remove()
                        installed = false
                    }
                } else {
                    Button(app.t("settings.generativeInstall")) { install() }
                }
            }
            if let failure {
                Text(failure).font(Typography.caption).foregroundStyle(Brand.error)
            }
        }
    }

    private func install() {
        failure = nil
        progress = 0
        Task {
            do {
                try await GenerativeInpainter.shared.install { value in
                    Task { @MainActor in progress = value }
                }
                installed = true
            } catch {
                failure = error.localizedDescription
            }
            progress = nil
        }
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
