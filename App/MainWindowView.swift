import SwiftUI
import SwiftData

struct MainWindowView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
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
                .animation(Motion.snappy, value: app.module)

                StatusBarView()
            }
            .background(Palette.background)
            .overlay(alignment: .bottom) {
                ToastOverlay().padding(.bottom, 46)
            }
            .overlay(alignment: .topTrailing) {
                if app.showDiagnostics {
                    DiagnosticsPanel()
                        .padding(14)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Motion.snappy, value: app.showDiagnostics)
        }
        .overlay {
            if app.culling.presenting {
                PresentationView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(Motion.smooth, value: app.culling.presenting)
        .toolbar(app.culling.presenting ? .hidden : .visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                PillPicker(selection: $app.module, options: AppModule.allCases) { module, _ in
                    Label(app.t(module.labelKey), systemImage: module.icon)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            // Idioma e tema vivem nas Definições (⌘,); aqui fica só o atalho.
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Image(systemName: "gearshape")
                        .accessibilityLabel(app.t("toolbar.settings"))
                }
                .help(app.t("toolbar.settings"))
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Photo.importedAt) private var photos: [Photo]
    @Query(sort: \UploadDestination.createdAt) private var destinations: [UploadDestination]
    @State private var pendingRemoval: String?

    var body: some View {
        let sessions = Dictionary(grouping: photos, by: \.sessionName)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        List {
            Section(app.t("sidebar.library")) {
                SidebarRow(title: app.t("sidebar.allPhotos"), icon: "photo.on.rectangle.angled", count: photos.count, active: app.culling.session == nil) {
                    app.culling.session = nil
                    app.module = .culling
                }
            }
            Section(app.t("sidebar.folders")) {
                if sessions.isEmpty {
                    SidebarPlaceholder(title: app.t("sidebar.empty"), icon: "folder")
                }
                ForEach(sessions, id: \.name) { session in
                    SidebarRow(title: session.name, icon: "folder.fill", count: session.count, active: app.culling.session == session.name) {
                        app.culling.session = session.name
                        app.module = .culling
                    }
                    .contextMenu {
                        Button(app.t("sidebar.removeFromCatalog"), role: .destructive) { pendingRemoval = session.name }
                    }
                }
            }
            Section(app.t("sidebar.destinations")) {
                if destinations.isEmpty {
                    SidebarPlaceholder(title: app.t("sidebar.empty"), icon: "server.rack")
                }
                ForEach(destinations) { destination in
                    DestinationDropRow(destination: destination)
                }
            }
            if app.culling.isImporting {
                Section(app.t("import.importing")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(Int(app.culling.importProgress * 100))%")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Brand.orange)
                            .contentTransition(.numericText())
                        BrandProgressBar(value: app.culling.importProgress)
                    }
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
        .listStyle(.sidebar)
        .animation(Motion.snappy, value: app.culling.isImporting)
        .animation(Motion.snappy, value: sessions.count)
        .safeAreaInset(edge: .bottom) { SidebarBrand() }
        // Uma pasta inteira pode ser um dia de trabalho: vale a pena confirmar antes de a tirar do catálogo.
        .confirmationDialog(
            String(format: app.t("sidebar.removeFolderConfirm"), pendingRemoval ?? ""),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button(app.t("sidebar.removeFromCatalog"), role: .destructive) {
                guard let name = pendingRemoval else { return }
                if app.culling.session == name { app.culling.session = nil }
                CatalogService.remove(photos.filter { $0.sessionName == name }, from: context)
                pendingRemoval = nil
            }
            Button(app.t("common.cancel"), role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(app.t("sidebar.removeFolderMessage"))
        }
    }
}

private struct SidebarBrand: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        HStack(spacing: 9) {
            EyeApertureMark()
                .frame(width: 26)
                .shadow(color: Brand.orange.opacity(0.5), radius: 5)
            VStack(alignment: .leading, spacing: 0) {
                Text("Photographer's Pocket Knife")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                Text("v\(version)")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct SidebarRow: View {
    let title: String
    let icon: String
    let count: Int
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? AnyShapeStyle(Brand.diagonal) : AnyShapeStyle(Palette.textSecondary))
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .fontWeight(active ? .semibold : .regular)
                    .foregroundStyle(Palette.textPrimary)
                    .layoutPriority(1)
                Spacer(minLength: 2)
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(active ? Brand.orange.opacity(0.2) : Palette.separator.opacity(0.6)))
                    .foregroundStyle(active ? Brand.orange : Palette.textSecondary)
                    .fixedSize()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(active ? Brand.orange.opacity(0.12) : (hovering ? Palette.separator.opacity(0.45) : .clear)))
            .overlay(alignment: .leading) {
                if active {
                    Capsule().fill(Brand.diagonal).frame(width: 3, height: 16).offset(x: -3).transition(.scale)
                }
            }
            .contentShape(Rectangle())
            .animation(Motion.snappy, value: active)
            .animation(Motion.snappy, value: count)
        }
        .buttonStyle(.plain)
        .onHover { hover in withAnimation(Motion.snappy) { hovering = hover } }
    }
}

private struct SidebarPlaceholder: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12))
            .foregroundStyle(Palette.textSecondary.opacity(0.8))
            .padding(.horizontal, 8)
    }
}

/// Largar fotos em cima de um destino envia-as logo para a fila.
struct DestinationDropRow: View {
    @Environment(AppState.self) private var app
    let destination: UploadDestination
    @AppStorage(DestinationDefaults.key) private var defaultIDString = ""
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: destination.transferProtocol.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(targeted ? AnyShapeStyle(Brand.diagonal) : AnyShapeStyle(Palette.textSecondary))
                .frame(width: 18)
            Text(destination.name).lineLimit(1)
            if destination.id.uuidString == defaultIDString {
                Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Brand.burntYellow)
            }
            Spacer()
            Text(destination.transferProtocol.displayName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.textSecondary)
            DestinationStatusDot(status: destination.testStatus)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(targeted ? Brand.orange.opacity(0.25) : (hovering ? Palette.separator.opacity(0.45) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(targeted ? Brand.orange : .clear, lineWidth: 1.5))
        .shadow(color: Brand.orange.opacity(targeted ? 0.6 : 0), radius: 8)
        .scaleEffect(targeted ? 1.04 : 1)
        .contentShape(Rectangle())
        .animation(Motion.snappy, value: targeted)
        .onHover { hover in withAnimation(Motion.snappy) { hovering = hover } }
        .onTapGesture { app.module = .upload }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            guard !files.isEmpty else { return false }
            app.transfers.enqueue(files: files, destination: destination, event: app.culling.session ?? "")
            app.showToast(String(format: app.t("upload.filesSelected"), files.count) + " → " + destination.name, icon: "arrow.up.circle.fill")
            return true
        } isTargeted: { targeted = $0 }
    }
}

struct StatusBarView: View {
    @Environment(AppState.self) private var app
    @State private var freeSpace: Int64?

    var body: some View {
        HStack(spacing: 16) {
            Label {
                Text(String(format: app.t("status.selected"), app.culling.selection.count))
                    .contentTransition(.numericText())
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            if let count = app.culling.lastImportCount, !app.culling.isImporting {
                Label(String(format: app.t("status.imported"), count), systemImage: "photo.stack")
                    .transition(.opacity)
            }
            Spacer()
            if let freeSpace {
                Label(String(format: app.t("status.freeSpace"), ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)), systemImage: "internaldrive")
            }
            HStack(spacing: 3) {
                PulsingDot(color: connectionColor, pulsing: app.transfers.connectionState == .transferring)
                Text(connectionText).contentTransition(.opacity)
            }
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Palette.panel)
        .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
        .animation(Motion.snappy, value: app.culling.selection.count)
        .animation(Motion.snappy, value: app.transfers.connectionState)
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
