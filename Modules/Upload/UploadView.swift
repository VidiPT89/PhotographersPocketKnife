import SwiftUI
import SwiftData

enum UploadTab: String, CaseIterable, Identifiable {
    case queue, destinations, history
    var id: String { rawValue }
    var labelKey: String { "upload.tab.\(rawValue)" }
}

struct UploadView: View {
    @Environment(AppState.self) private var app
    @State private var tab: UploadTab = .queue

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(UploadTab.allCases) { Text(app.t($0.labelKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            switch tab {
            case .queue: TransferQueueView(showDestinations: { tab = .destinations })
            case .destinations: DestinationsView()
            case .history: UploadHistoryView()
            }
        }
        .sheet(isPresented: Binding(
            get: { !app.pendingUploadURLs.isEmpty },
            set: { if !$0 { app.pendingUploadURLs = [] } }
        )) {
            EnqueueSheet(files: app.pendingUploadURLs, showDestinations: { tab = .destinations })
        }
    }
}

struct TransferQueueView: View {
    @Environment(AppState.self) private var app
    let showDestinations: () -> Void

    var body: some View {
        let queue = app.transfers
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: app.t("upload.summary"), queue.completedCount, queue.items.count, queue.failedCount))
                        .font(Typography.body)
                    ShimmerProgressBar(value: queue.overallProgress, active: queue.connectionState == .transferring)
                        .frame(maxWidth: 360)
                }
                Spacer()
                Button(app.t("upload.addFiles"), systemImage: "plus") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK { app.pendingUploadURLs = panel.urls }
                }
                if queue.isPaused {
                    Button(app.t("upload.resume"), systemImage: "play.fill") { queue.resume() }
                } else {
                    Button(app.t("upload.pause"), systemImage: "pause.fill") { queue.pause() }
                        .disabled(queue.connectionState != .transferring)
                }
                Button(app.t("upload.retryFailed"), systemImage: "arrow.clockwise") { queue.retryFailed() }
                    .disabled(queue.failedCount == 0)
                Button(app.t("upload.clearFinished"), systemImage: "checkmark.circle") { queue.clearFinished() }
                    .disabled(queue.completedCount == 0)
            }
            .controlSize(.small)
            .padding(12)

            if queue.items.isEmpty {
                EmptyModuleView(
                    systemImage: "arrow.up.to.line.circle",
                    title: app.t("upload.empty.title"),
                    subtitle: app.t("upload.empty.subtitle"),
                    actionTitle: app.t("upload.tab.destinations"),
                    action: showDestinations
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(queue.items) { item in
                    TransferRow(item: item)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            guard !files.isEmpty else { return false }
            app.pendingUploadURLs = files
            return true
        }
    }
}

struct TransferRow: View {
    @Environment(AppState.self) private var app
    let item: TransferItem

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.fileURL.lastPathComponent).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(statusText).font(Typography.caption).foregroundStyle(statusColor)
                }
                Text("\(item.destinationName) · \(item.remotePath)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.status == .running || item.status == .waitingRetry {
                    BrandProgressBar(value: item.progress)
                        .animation(Motion.smooth, value: item.progress)
                }
            }
            if case .failed = item.status {
                Button { app.transfers.retry(item) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            Button { app.transfers.remove(item) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending: Image(systemName: "clock").foregroundStyle(Palette.textSecondary)
        case .running: ProgressView().controlSize(.mini)
        case .waitingRetry: Image(systemName: "arrow.clockwise").foregroundStyle(Brand.burntYellow)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.success).transition(.scale)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.error)
        }
    }

    private var statusText: String {
        switch item.status {
        case .pending: app.t("transfer.pending")
        case .running: "\(Int(item.progress * 100))%"
        case .waitingRetry: String(format: app.t("transfer.retrying"), item.attempts)
        case .done: app.t("transfer.done")
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .done: Brand.success
        case .failed: Brand.error
        default: Palette.textSecondary
        }
    }
}

/// Barra de progresso com o gradiente da marca a deslizar enquanto há transferências.
struct ShimmerProgressBar: View {
    let value: Double
    let active: Bool
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.separator)
                Capsule()
                    .fill(Brand.gradient)
                    .overlay {
                        if active {
                            LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 60)
                                .offset(x: phase * geo.size.width)
                        }
                    }
                    .clipShape(Capsule())
                    .frame(width: geo.size.width * min(max(value, 0), 1))
                    .animation(Motion.smooth, value: value)
            }
        }
        .frame(height: 6)
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

struct EnqueueSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \UploadDestination.name) private var destinations: [UploadDestination]
    let files: [URL]
    let showDestinations: () -> Void

    @State private var destinationID: UUID?
    @State private var event = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(String(format: app.t("upload.filesSelected"), files.count)) {
                    if destinations.isEmpty {
                        Text(app.t("upload.noDestinations")).foregroundStyle(Palette.textSecondary)
                        Button(app.t("upload.tab.destinations")) {
                            dismiss()
                            showDestinations()
                        }
                    } else {
                        Picker(app.t("upload.destination"), selection: $destinationID) {
                            Text("—").tag(UUID?.none)
                            ForEach(destinations) { Text($0.name).tag(Optional($0.id)) }
                        }
                        TextField(app.t("rename.event"), text: $event)
                        if let destination = destinations.first(where: { $0.id == destinationID }) {
                            LabeledContent(app.t("destination.remoteFolder"), value: RemotePath.folder(template: destination.remoteFolderTemplate, date: Date(), event: event))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            SheetButtons(confirmTitle: app.t("upload.send"), confirmDisabled: destinationID == nil) {
                guard let destination = destinations.first(where: { $0.id == destinationID }) else { return }
                app.transfers.enqueue(files: files, destination: destination, event: event)
                dismiss()
            }
        }
        .frame(width: 460)
        .onAppear { destinationID = destinations.first?.id }
    }
}

struct UploadHistoryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \UploadRecord.date, order: .reverse) private var records: [UploadRecord]

    var body: some View {
        VStack(spacing: 0) {
            if records.isEmpty {
                EmptyModuleView(systemImage: "clock", title: app.t("history.upload.empty"), subtitle: "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(records) { record in
                    HStack(spacing: 10) {
                        Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(record.success ? Brand.success : Brand.error)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.fileName).font(.system(size: 12, weight: .medium))
                            Text("\(record.destinationName) · \(record.remotePath)")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                            if let message = record.errorMessage {
                                Text(message).font(Typography.caption).foregroundStyle(Brand.error)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                            Text(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file))
                        }
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    }
                }
                .scrollContentBackground(.hidden)
                HStack {
                    Spacer()
                    Button(app.t("history.upload.clear"), role: .destructive) {
                        records.forEach(context.delete)
                        try? context.save()
                    }
                }
                .padding(12)
            }
        }
    }
}
