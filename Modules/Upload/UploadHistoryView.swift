import SwiftUI
import SwiftData

struct UploadHistoryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \UploadRecord.date, order: .reverse) private var records: [UploadRecord]
    @State private var query = ""
    @State private var destination: String?
    @State private var status: UploadHistoryFilter.Status = .all
    @State private var confirmClear = false

    private var filtered: [UploadRecord] {
        records.filter {
            UploadHistoryFilter.matches(fileName: $0.fileName, remotePath: $0.remotePath, destinationName: $0.destinationName,
                                        success: $0.success, query: query, destination: destination, status: status)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if records.isEmpty {
                EmptyModuleView(systemImage: "clock", title: app.t("history.upload.empty"), subtitle: "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let rows = filtered
                filterBar
                Divider()
                if rows.isEmpty {
                    EmptyModuleView(systemImage: "line.3.horizontal.decrease.circle", title: app.t("history.filter.none"), subtitle: "")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(rows) { UploadRecordRow(record: $0) }
                        .scrollContentBackground(.hidden)
                }
                HStack(spacing: 12) {
                    Button(app.t("history.upload.report"), systemImage: "tablecells") { exportReport(rows) }
                        .disabled(rows.isEmpty)
                    Text(String(format: app.t("history.upload.totals"), rows.count,
                                ByteCountFormatter.string(fromByteCount: rows.filter(\.success).reduce(0) { $0 + $1.bytes }, countStyle: .file)))
                        .font(Typography.caption.monospacedDigit())
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Button(app.t("history.upload.clear"), role: .destructive) { confirmClear = true }
                }
                .padding(12)
            }
        }
        .confirmationDialog(app.t("history.upload.clearConfirm"), isPresented: $confirmClear) {
            Button(app.t("history.upload.clear"), role: .destructive) {
                records.forEach(context.delete)
                try? context.save()
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            TextField(app.t("history.filter.search"), text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            Picker(app.t("upload.destination"), selection: $destination) {
                Text(app.t("history.filter.allDestinations")).tag(String?.none)
                ForEach(Array(Set(records.map(\.destinationName))).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            Picker(app.t("history.filter.all"), selection: $status) {
                ForEach(UploadHistoryFilter.Status.allCases) { Text(app.t($0.labelKey)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 240)
            Spacer()
        }
        .controlSize(.small)
        .padding(12)
    }

    private func exportReport(_ rows: [UploadRecord]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "upload-report-\(PhotoImporter.dayString(Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let reportRows = rows.map {
            UploadReport.Row(date: $0.date, fileName: $0.fileName, destination: $0.destinationName, remotePath: $0.remotePath,
                             bytes: $0.bytes, success: $0.success, error: $0.errorMessage)
        }
        do {
            try UploadReport.csv(reportRows).write(to: url, atomically: true, encoding: .utf8)
            app.showToast(app.t("toast.report"), icon: "tablecells.fill")
        } catch {
            app.showToast(error.localizedDescription, icon: "exclamationmark.triangle.fill")
        }
    }
}

private struct UploadRecordRow: View {
    let record: UploadRecord

    var body: some View {
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
}
