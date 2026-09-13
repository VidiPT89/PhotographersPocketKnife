import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            if app.isSplashVisible {
                SplashScreenView {
                    withAnimation(.easeInOut(duration: 0.5)) { app.isSplashVisible = false }
                }
                .transition(.opacity)
            } else {
                MainWindowView()
                    .transition(.opacity)
            }
        }
    }
}

struct MainWindowView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app

        NavigationSplitView {
            List {
                Section(app.t("sidebar.folders")) {
                    Label(app.t("sidebar.empty"), systemImage: "folder").foregroundStyle(.secondary)
                }
                Section(app.t("sidebar.destinations")) {
                    Label(app.t("sidebar.empty"), systemImage: "server.rack").foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                ZStack {
                    switch app.module {
                    case .culling: CullingView().transition(Motion.moduleTransition)
                    case .editing: EditingView().transition(Motion.moduleTransition)
                    case .upload: UploadView().transition(Motion.moduleTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Motion.smooth, value: app.module)

                StatusBarView()
            }
            .background(Palette.background)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $app.module) {
                    ForEach(AppModule.allCases) { module in
                        Label(app.t(module.labelKey), systemImage: module.icon).tag(module)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                LanguageMenu()
                ThemeMenu()
            }
        }
    }
}

struct LanguageMenu: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Menu(app.language.shortLabel) {
            ForEach(AppLanguage.allCases) { lang in
                Button(lang.shortLabel) { app.language = lang }
            }
        }
        .help(app.t("toolbar.language"))
    }
}

struct ThemeMenu: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Menu {
            ForEach(AppTheme.allCases) { theme in
                Button(app.t(theme.labelKey)) { app.theme = theme }
            }
        } label: {
            Image(systemName: "circle.lefthalf.filled")
        }
        .help(app.t("toolbar.theme"))
    }
}

struct StatusBarView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack {
            Text(String(format: app.t("status.selected"), 0))
            Spacer()
            Label(app.t("status.offline"), systemImage: "circle.fill")
                .labelStyle(StatusDotLabelStyle(color: Palette.textSecondary))
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.panel)
    }
}

private struct StatusDotLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(color)
            configuration.title
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Picker(app.t("toolbar.language"), selection: $app.language) {
                ForEach(AppLanguage.allCases) { Text($0.shortLabel).tag($0) }
            }
            Picker(app.t("toolbar.theme"), selection: $app.theme) {
                ForEach(AppTheme.allCases) { Text(app.t($0.labelKey)).tag($0) }
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
