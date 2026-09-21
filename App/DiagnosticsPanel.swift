import SwiftUI
import SwiftData

/// Painel de diagnóstico (⌥⌘D): tamanho do catálogo, memória, cache e tempos de decode/render/exportação.
struct DiagnosticsPanel: View {
    @Environment(AppState.self) private var app
    @Query private var photos: [Photo]

    @State private var stats: [Diagnostics.Operation: Diagnostics.Stat] = [:]
    @State private var memory: UInt64 = 0
    @State private var cacheBytes: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(Brand.diagonal)
                Text(app.t("diagnostics.title")).font(.system(size: 13, weight: .bold))
                Spacer()
                Button { withAnimation(Motion.snappy) { app.showDiagnostics = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .hint(app.t("common.close"))
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row(app.t("diagnostics.photos"), "\(photos.count)")
                row(app.t("diagnostics.memory"), ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory))
                row(app.t("diagnostics.cache"), ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                row(app.t("diagnostics.queue"), "\(app.transfers.items.count)")
            }

            Divider()

            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    header(app.t("diagnostics.last"))
                    header(app.t("diagnostics.average"))
                    header(app.t("diagnostics.max"))
                    header("#")
                }
                ForEach(Diagnostics.Operation.allCases, id: \.self) { operation in
                    let stat = stats[operation] ?? Diagnostics.Stat()
                    GridRow {
                        Text(app.t(operation.labelKey)).gridColumnAlignment(.leading)
                        value(stat.last, highlight: stat.last > target(operation))
                        value(stat.average, highlight: stat.average > target(operation))
                        value(stat.max, highlight: false)
                        Text("\(stat.count)").foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            .font(.system(size: 11, design: .monospaced))

            HStack {
                Text(app.t("diagnostics.hint")).font(Typography.caption).foregroundStyle(Palette.textSecondary)
                Spacer()
                Button(app.t("diagnostics.reset")) {
                    Diagnostics.shared.reset()
                    stats = [:]
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.orange.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
        .task {
            while !Task.isCancelled {
                stats = Diagnostics.shared.snapshot()
                memory = Diagnostics.memoryFootprint
                cacheBytes = await Task.detached(priority: .utility) { ThumbnailCache.shared.diskUsage() }.value
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Metas do plano: foto seguinte < 100 ms, render do slider ~16 ms (60 fps), exportação 24 MP < 1,5 s.
    private func target(_ operation: Diagnostics.Operation) -> Double {
        switch operation {
        case .thumbnail: 100
        case .preview: 60
        case .export: 1500
        case .importFile: 20
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(Palette.textSecondary)
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .font(Typography.caption)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.textSecondary)
    }

    private func value(_ milliseconds: Double, highlight: Bool) -> some View {
        Text(milliseconds == 0 ? "—" : String(format: "%.0f ms", milliseconds))
            .foregroundStyle(highlight ? Brand.error : Palette.textPrimary)
            .contentTransition(.numericText())
    }
}
