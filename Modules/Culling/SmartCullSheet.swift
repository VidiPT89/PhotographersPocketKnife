import SwiftUI

enum CullMode: String, CaseIterable, Identifiable {
    case assisted, automatic
    var id: String { rawValue }
    var labelKey: String { "cull.mode.\(rawValue)" }
    var hintKey: String { "cull.mode.\(rawValue)Hint" }
    var icon: String { self == .assisted ? "hand.point.up.left.fill" : "wand.and.stars" }
}

/// Seleção inteligente: assistida (a app analisa, tu decides) ou automática (a app classifica, podes desfazer).
struct SmartCullSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let photos: [Photo]

    @AppStorage("cull.mode") private var mode: CullMode = .assisted
    @AppStorage("cull.keepPerMoment") private var keepPerMoment = 1
    @AppStorage("cull.rejectProblems") private var rejectProblems = true
    @AppStorage("cull.assignStars") private var assignStars = true
    @AppStorage("cull.keepManual") private var keepManual = true
    @AppStorage("cull.blurTolerance") private var blurTolerance = 0.5
    @State private var finished = false
    @State private var applied: (picks: Int, rejects: Int)?

    private var options: CullOptions {
        var options = CullOptions()
        options.keepPerMoment = keepPerMoment
        options.rejectProblems = rejectProblems
        options.assignStars = assignStars
        options.keepManualDecisions = keepManual
        options.blurTolerance = blurTolerance
        return options
    }

    var body: some View {
        let culling = app.culling
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent(app.t("cull.photos"), value: "\(photos.count)")
                    Picker(app.t("cull.title"), selection: $mode) {
                        ForEach(CullMode.allCases) { Label(app.t($0.labelKey), systemImage: $0.icon).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(culling.isAnalyzing || finished)
                    Text(app.t(mode.hintKey))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                if !finished {
                    Section {
                        LabeledContent(app.t("cull.blurTolerance")) {
                            Slider(value: $blurTolerance, in: 0...1).tint(Brand.orange).frame(width: 180)
                        }
                        if mode == .automatic {
                            Stepper("\(app.t("cull.keepPerMoment")): \(keepPerMoment)", value: $keepPerMoment, in: 1...5)
                            Toggle(app.t("cull.rejectProblems"), isOn: $rejectProblems)
                            Toggle(app.t("cull.assignStars"), isOn: $assignStars)
                            Toggle(app.t("cull.keepManual"), isOn: $keepManual)
                        }
                    }
                    .disabled(culling.isAnalyzing)
                }
                if culling.isAnalyzing {
                    Section {
                        ProgressView(value: Double(culling.analysisDone), total: Double(max(culling.analysisTotal, 1))) {
                            Text(String(format: app.t("cull.analysing"), culling.analysisDone, culling.analysisTotal))
                                .font(Typography.caption)
                        }
                        .tint(Brand.orange)
                    }
                } else if finished, let report = culling.cullReport {
                    Section(app.t("cull.summary")) {
                        LabeledContent(app.t("cull.summary.moments"), value: "\(report.momentCount)")
                        LabeledContent {
                            Text("\(report.best.count)")
                        } label: {
                            Label(app.t("cull.summary.best"), systemImage: "crown.fill")
                        }
                        ForEach(CullIssue.allCases) { issue in
                            let count = report.issues.values.filter { $0.contains(issue) }.count
                            if count > 0 {
                                LabeledContent {
                                    Text("\(count)")
                                } label: {
                                    Label(app.t(issue.labelKey), systemImage: issue.icon)
                                }
                            }
                        }
                        if let applied {
                            Text(String(format: app.t("toast.cullApplied"), applied.picks, applied.rejects))
                                .foregroundStyle(Brand.orange)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .formStyle(.grouped)

            HStack {
                if applied != nil, culling.canUndoAutomaticCull {
                    Button(app.t("cull.undo")) {
                        culling.undoAutomaticCull(in: photos)
                        applied = nil
                    }
                }
                Spacer()
                Button(app.t(finished ? "cull.done" : "cull.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !finished {
                    PrimaryButton(title: app.t("cull.start"), systemImage: mode.icon) { start() }
                        .disabled(culling.isAnalyzing || photos.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 500)
        .animation(Motion.smooth, value: mode)
        .animation(Motion.smooth, value: finished)
    }

    private func start() {
        let options = options
        let culling = app.culling
        let mode = mode
        Task {
            await culling.analyze(photos, options: options)
            if mode == .automatic {
                applied = culling.applyAutomatic(to: photos, options: options)
            } else {
                culling.sort = .score
                culling.sortAscending = false
            }
            finished = true
        }
    }
}

/// Análise de uma foto no painel lateral.
struct CullAnalysisView: View {
    @Environment(AppState.self) private var app
    let badge: CullBadge

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(app.t("cull.score")).foregroundStyle(Palette.textSecondary)
                Spacer()
                Text("\(Int((badge.score * 100).rounded()))")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.orange)
                    .contentTransition(.numericText())
            }
            ProgressView(value: badge.score).tint(Brand.orange)
            Label(String(format: app.t(badge.isBest ? "cull.bestOfMoment" : "cull.moment"), badge.moment + 1),
                  systemImage: badge.isBest ? "crown.fill" : "square.stack")
                .foregroundStyle(badge.isBest ? Brand.amber : Palette.textSecondary)
            if badge.issues.isEmpty {
                Label(app.t("cull.noIssues"), systemImage: "checkmark.seal.fill").foregroundStyle(Brand.success)
            } else {
                ForEach(badge.issues) { issue in
                    Label(app.t(issue.labelKey), systemImage: issue.icon).foregroundStyle(Brand.error)
                }
            }
        }
        .font(Typography.caption)
    }
}

/// Pontuação, problemas e coroa da melhor do momento, por cima da miniatura.
struct CullBadgeView: View {
    let badge: CullBadge

    var body: some View {
        HStack(spacing: 3) {
            if badge.isBest {
                Image(systemName: "crown.fill").foregroundStyle(Brand.amber)
            }
            Text("\(Int((badge.score * 100).rounded()))")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
            ForEach(badge.issues) { issue in
                Image(systemName: issue.icon).foregroundStyle(Brand.error)
            }
        }
        .font(.system(size: 9, weight: .bold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.black.opacity(0.62), in: Capsule())
        .foregroundStyle(.white)
    }
}
