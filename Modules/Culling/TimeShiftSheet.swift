import SwiftUI
import SwiftData

enum TimeShift {
    /// `+1 h 02 min 05 s`, `−45 s`, `0 s`.
    static func describe(_ offset: TimeInterval) -> String {
        let total = Int(offset.rounded())
        guard total != 0 else { return "0 s" }
        let sign = total > 0 ? "+" : "−"
        var rest = abs(total)
        let hours = rest / 3600
        rest %= 3600
        let minutes = rest / 60
        let seconds = rest % 60
        if hours > 0 { return "\(sign)\(hours) h \(String(format: "%02d", minutes)) min \(String(format: "%02d", seconds)) s" }
        if minutes > 0 { return "\(sign)\(minutes) min \(String(format: "%02d", seconds)) s" }
        return "\(sign)\(seconds) s"
    }
}

/// Acerta a hora de captura (ex. sincronizar duas câmaras): a diferença medida numa foto aplica-se a todas.
struct TimeShiftSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let photos: [Photo]

    @State private var corrected = Date()

    private var reference: Photo? {
        photos.filter { $0.captureDate != nil }.min { ($0.captureDate ?? .distantFuture) < ($1.captureDate ?? .distantFuture) }
    }

    private var offset: TimeInterval {
        guard let original = reference?.captureDate else { return 0 }
        return corrected.timeIntervalSince(original).rounded()
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(String(format: app.t("timeShift.applyTo"), photos.count)) {
                    if let reference, let original = reference.captureDate {
                        LabeledContent(app.t("timeShift.reference"), value: [reference.fileName, reference.camera].compactMap { $0 }.joined(separator: " · "))
                        LabeledContent(app.t("timeShift.original"), value: original.formatted(date: .abbreviated, time: .standard))
                        DatePicker(app.t("timeShift.corrected"), selection: $corrected, displayedComponents: [.date, .hourAndMinute])
                        // O DatePicker do macOS não mostra segundos; acertam-se aqui.
                        Stepper(value: Binding(
                            get: { Calendar.current.component(.second, from: corrected) },
                            set: { corrected.addTimeInterval(TimeInterval($0 - Calendar.current.component(.second, from: corrected))) }
                        ), in: -1...60) {
                            LabeledContent(app.t("timeShift.seconds"), value: String(format: "%02d", Calendar.current.component(.second, from: corrected)))
                        }
                        HStack {
                            Button("−1 h") { corrected.addTimeInterval(-3600) }
                            Button("+1 h") { corrected.addTimeInterval(3600) }
                            Spacer()
                            Text(TimeShift.describe(offset))
                                .font(Typography.body.monospacedDigit())
                                .foregroundStyle(offset == 0 ? Palette.textSecondary : Brand.orange)
                        }
                        .controlSize(.small)
                    } else {
                        Text(app.t("timeShift.noDates")).foregroundStyle(Palette.textSecondary)
                    }
                }
                Text(app.t("timeShift.hint"))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .formStyle(.grouped)
            SheetButtons(confirmTitle: app.t("timeShift.apply"), confirmDisabled: offset == 0) { apply() }
        }
        .frame(width: 500, height: 400)
        .onAppear { corrected = reference?.captureDate ?? Date() }
    }

    private func apply() {
        let shift = offset
        var changed = 0
        for photo in photos {
            guard let date = photo.captureDate else { continue }
            photo.captureDate = date.addingTimeInterval(shift)
            changed += 1
        }
        try? context.save()
        app.showToast(String(format: app.t("toast.timeShift"), changed), icon: "clock.arrow.2.circlepath")
        dismiss()
    }
}
