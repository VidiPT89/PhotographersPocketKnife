import SwiftUI
import SwiftData

/// Escolhe as fotos de ISO alto e manda-as para a redução de ruído em segundo plano.
struct DenoiseSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let photos: [Photo]

    @AppStorage("denoise.minISO") private var minISO = 3200
    @AppStorage("denoise.automatic") private var automatic = true
    @AppStorage("denoise.strength") private var strength = 0.6

    private var targets: [Photo] { photos.filter { minISO == 0 || ($0.iso ?? 0) >= minISO } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker(app.t("denoise.minISO"), selection: $minISO) {
                        Text(app.t("denoise.allISO")).tag(0)
                        ForEach([1600, 3200, 6400, 12800], id: \.self) { Text("ISO \($0)+").tag($0) }
                    }
                    LabeledContent(app.t("denoise.photos"), value: "\(targets.count)")
                    Toggle(app.t("denoise.automatic"), isOn: $automatic)
                    if !automatic {
                        LabeledContent(app.t("denoise.strength")) {
                            Slider(value: $strength, in: 0.1...1).tint(Brand.orange).frame(width: 180)
                        }
                    }
                }
                Text(app.t("denoise.hint"))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .formStyle(.grouped)
            SheetButtons(confirmTitle: app.t("denoise.start"), confirmDisabled: targets.isEmpty || app.denoise.isRunning) { start() }
        }
        .frame(width: 480, height: 360)
    }

    private func start() {
        let chosen = targets
        let jobs = chosen.map { DenoiseQueue.Job(url: $0.url, strength: automatic ? WaveletDenoise.suggestedStrength(iso: $0.iso) : strength) }
        app.denoise.start(jobs, session: chosen.first?.sessionName ?? "Denoise", culling: app.culling, context: context)
        app.showToast(String(format: app.t("denoise.started"), jobs.count), icon: "sparkles")
        dismiss()
    }
}
