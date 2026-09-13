import SwiftUI
import SwiftData

struct MainWindowView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
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

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Photo.importedAt) private var photos: [Photo]
    @Query(sort: \UploadDestination.createdAt) private var destinations: [UploadDestination]

    var body: some View {
        let sessions = Dictionary(grouping: photos, by: \.sessionName)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        List {
            Section(app.t("sidebar.library")) {
                SidebarRow(title: app.t("sidebar.allPhotos"), icon: "photo.on.rectangle", count: photos.count, active: app.culling.session == nil) {
                    app.culling.session = nil
                }
            }
            Section(app.t("sidebar.folders")) {
                if sessions.isEmpty {
                    Label(app.t("sidebar.empty"), systemImage: "folder").foregroundStyle(.secondary)
                }
                ForEach(sessions, id: \.name) { session in
                    SidebarRow(title: session.name, icon: "folder", count: session.count, active: app.culling.session == session.name) {
                        app.culling.session = session.name
                    }
                    .contextMenu {
                        Button(app.t("sidebar.removeFromCatalog"), role: .destructive) {
                            if app.culling.session == session.name { app.culling.session = nil }
                            CatalogService.remove(photos.filter { $0.sessionName == session.name }, from: context)
                        }
                    }
                }
            }
            Section(app.t("sidebar.destinations")) {
                if destinations.isEmpty {
                    Label(app.t("sidebar.empty"), systemImage: "server.rack").foregroundStyle(.secondary)
                }
                ForEach(destinations) { destination in
                    DestinationDropRow(destination: destination)
                }
            }
            if app.culling.isImporting {
                Section(app.t("import.importing")) {
                    BrandProgressBar(value: app.culling.importProgress)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct SidebarRow: View {
    let title: String
    let icon: String
    let count: Int
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundStyle(active ? Brand.orange : Palette.textPrimary)
                Spacer()
                Text("\(count)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Largar fotos em cima de um destino envia-as logo para a fila.
struct DestinationDropRow: View {
    @Environment(AppState.self) private var app
    let destination: UploadDestination
    @State private var targeted = false

    var body: some View {
        Label(destination.name, systemImage: "server.rack")
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(targeted ? Brand.orange.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .shadow(color: Brand.orange.opacity(targeted ? 0.6 : 0), radius: 6)
            .scaleEffect(targeted ? 1.04 : 1)
            .animation(Motion.smooth, value: targeted)
            .onTapGesture { app.module = .upload }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                guard !files.isEmpty else { return false }
                app.transfers.enqueue(files: files, destination: destination, event: app.culling.session ?? "")
                return true
            } isTargeted: { targeted = $0 }
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
    @State private var freeSpace: Int64?

    var body: some View {
        HStack(spacing: 16) {
            Text(String(format: app.t("status.selected"), app.culling.selection.count))
            if let count = app.culling.lastImportCount, !app.culling.isImporting {
                Text(String(format: app.t("status.imported"), count))
            }
            Spacer()
            if let freeSpace {
                Label(String(format: app.t("status.freeSpace"), ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)), systemImage: "internaldrive")
            }
            Label(connectionText, systemImage: "circle.fill")
                .labelStyle(StatusDotLabelStyle(color: connectionColor))
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.panel)
        .task {
            while !Task.isCancelled {
                let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                freeSpace = values?.volumeAvailableCapacityForImportantUsage
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var connectionText: String {
        switch app.transfers.connectionState {
        case .idle: app.t("status.offline")
        case .transferring: app.t("status.transferring")
        case .paused: app.t("status.paused")
        case .error: app.t("status.error")
        }
    }

    private var connectionColor: Color {
        switch app.transfers.connectionState {
        case .idle: Palette.textSecondary
        case .transferring: Brand.success
        case .paused: Brand.burntYellow
        case .error: Brand.error
        }
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
