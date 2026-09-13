import SwiftUI
import SwiftData

struct AdjustmentSpec: Identifiable {
    let labelKey: String
    let keyPath: WritableKeyPath<EditRecipe, Double>
    let range: ClosedRange<Double>
    var id: String { labelKey }

    @MainActor static let sections: [(titleKey: String, specs: [AdjustmentSpec])] = [
        ("adjust.light", [
            AdjustmentSpec(labelKey: "adjust.exposure", keyPath: \.exposure, range: -5...5),
            AdjustmentSpec(labelKey: "adjust.contrast", keyPath: \.contrast, range: -1...1),
            AdjustmentSpec(labelKey: "adjust.highlights", keyPath: \.highlights, range: -1...1),
            AdjustmentSpec(labelKey: "adjust.shadows", keyPath: \.shadows, range: -1...1),
            AdjustmentSpec(labelKey: "adjust.whites", keyPath: \.whites, range: -1...1),
            AdjustmentSpec(labelKey: "adjust.blacks", keyPath: \.blacks, range: -1...1),
        ]),
        ("adjust.color", [
            AdjustmentSpec(labelKey: "adjust.temperature", keyPath: \.temperature, range: -1...1),
            AdjustmentSpec(labelKey: "adjust.tint", keyPath: \.tint, range: -1...1),
            AdjustmentSpec(labelKey: "adjust.vibrance", keyPath: \.vibrance, range: -1...1),
            AdjustmentSpec(labelKey: "adjust.saturation", keyPath: \.saturation, range: -1...1),
        ]),
        ("adjust.detail", [
            AdjustmentSpec(labelKey: "adjust.sharpness", keyPath: \.sharpness, range: 0...1),
            AdjustmentSpec(labelKey: "adjust.noise", keyPath: \.noiseReduction, range: 0...1),
        ]),
        ("adjust.effects", [
            AdjustmentSpec(labelKey: "adjust.vignette", keyPath: \.vignette, range: -1...1),
        ]),
    ]
}

struct AdjustmentPanel: View {
    @Environment(AppState.self) private var app
    let list: [Photo]

    var body: some View {
        @Bindable var editing = app.editing
        VStack(spacing: 0) {
            HistogramView(data: editing.histogram)
                .frame(height: 80)
                .padding(12)

            Picker("", selection: $editing.tab) {
                ForEach(EditTab.allCases) { tab in
                    Image(systemName: tab.icon).help(app.t(tab.labelKey)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)

            Text(app.t(editing.tab.labelKey))
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch editing.tab {
                    case .basic: basic
                    case .curve: CurvePanel()
                    case .hsl: HSLPanel()
                    case .geometry: GeometryPanel()
                    case .presets: PresetsPanel(list: list)
                    case .history: HistoryPanel()
                    }
                }
                .padding(12)
                .animation(Motion.smooth, value: editing.tab)
            }
        }
        .background(Palette.panel)
        .controlSize(.small)
    }

    private var basic: some View {
        ForEach(AdjustmentSpec.sections, id: \.titleKey) { section in
            PanelHeader(title: app.t(section.titleKey))
            ForEach(section.specs) { spec in
                AdjustmentSlider(labelKey: spec.labelKey, value: spec.keyPath, range: spec.range)
            }
        }
    }
}

/// Slider ligado à receita: atualiza a preview ao arrastar e grava no histórico ao largar.
/// Duplo clique no nome repõe o valor.
struct AdjustmentSlider: View {
    @Environment(AppState.self) private var app
    let labelKey: String
    let value: WritableKeyPath<EditRecipe, Double>
    let range: ClosedRange<Double>
    var tint: Color = Brand.orange

    var body: some View {
        let editing = app.editing
        let current = editing.recipe[keyPath: value]
        VStack(spacing: 2) {
            HStack {
                Text(app.t(labelKey))
                    .onTapGesture(count: 2) {
                        editing.recipe[keyPath: value] = 0
                        editing.commit(labelKey)
                    }
                Spacer()
                Text(String(format: "%+.2f", current))
                    .monospacedDigit()
                    .foregroundStyle(current == 0 ? Palette.textSecondary : Brand.orange)
            }
            .font(Typography.caption)
            Slider(
                value: Binding(
                    get: { current },
                    set: { newValue in
                        editing.recipe[keyPath: value] = newValue
                        editing.scheduleRender()
                    }
                ),
                in: range
            ) { isEditing in
                if !isEditing { editing.commit(labelKey) }
            }
            .tint(tint)
        }
    }
}

struct CurvePanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var editing = app.editing
        Picker("", selection: $editing.curveChannel) {
            ForEach(CurveChannel.allCases) { Text(app.t($0.labelKey)).tag($0) }
        }
        .pickerStyle(.segmented)
        CurveEditor(channel: editing.curveChannel)
            .aspectRatio(1, contentMode: .fit)
        Text(app.t("curve.hint"))
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
        Button(app.t("curve.reset")) {
            editing.recipe.setCurve(EditRecipe.linearCurve, for: editing.curveChannel)
            editing.commit("history.curve")
        }
    }
}

struct CurveEditor: View {
    @Environment(AppState.self) private var app
    let channel: CurveChannel
    @State private var dragIndex: Int?

    private var color: Color {
        switch channel {
        case .master: .white
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }

    var body: some View {
        let points = app.editing.recipe.curve(channel)
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.6))
                Path { path in
                    for f in [0.25, 0.5, 0.75] {
                        path.move(to: CGPoint(x: size.width * f, y: 0))
                        path.addLine(to: CGPoint(x: size.width * f, y: size.height))
                        path.move(to: CGPoint(x: 0, y: size.height * f))
                        path.addLine(to: CGPoint(x: size.width, y: size.height * f))
                    }
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)

                let curve = MonotoneCurve(points)
                Path { path in
                    for step in 0...64 {
                        let x = Double(step) / 64
                        let point = CGPoint(x: x * size.width, y: (1 - min(max(curve.evaluate(x), 0), 1)) * size.height)
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(color, lineWidth: 1.5)

                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(dragIndex == index ? Brand.orange : color)
                        .frame(width: 10, height: 10)
                        .position(x: point.x * size.width, y: (1 - point.y) * size.height)
                        .onTapGesture(count: 2) { removePoint(index) }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in drag(value, size: size) }
                    .onEnded { _ in
                        dragIndex = nil
                        app.editing.commit("history.curve")
                    }
            )
        }
    }

    private func drag(_ value: DragGesture.Value, size: CGSize) {
        let editing = app.editing
        var points = editing.recipe.curve(channel)
        let location = CurvePoint(
            x: min(max(value.location.x / size.width, 0), 1),
            y: min(max(1 - value.location.y / size.height, 0), 1)
        )
        if dragIndex == nil {
            // Agarra o ponto mais próximo; se não houver nenhum perto, cria um novo.
            let nearest = points.enumerated().min { hypot($0.element.x - location.x, $0.element.y - location.y) < hypot($1.element.x - location.x, $1.element.y - location.y) }
            if let nearest, hypot(nearest.element.x - location.x, nearest.element.y - location.y) < 0.06 {
                dragIndex = nearest.offset
            } else {
                points.append(location)
                points.sort { $0.x < $1.x }
                dragIndex = points.firstIndex(of: location)
            }
        }
        guard let index = dragIndex, points.indices.contains(index) else { return }
        let lower = index > 0 ? points[index - 1].x + 0.01 : 0
        let upper = index < points.count - 1 ? points[index + 1].x - 0.01 : 1
        points[index] = CurvePoint(x: min(max(location.x, lower), upper), y: location.y)
        editing.recipe.setCurve(points, for: channel)
        editing.scheduleRender()
    }

    private func removePoint(_ index: Int) {
        var points = app.editing.recipe.curve(channel)
        guard points.count > 2 else { return }
        points.remove(at: index)
        app.editing.recipe.setCurve(points, for: channel)
        app.editing.commit("history.curve")
    }
}

struct HSLPanel: View {
    @Environment(AppState.self) private var app

    private static let bandColors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]

    var body: some View {
        @Bindable var editing = app.editing
        Picker("", selection: $editing.hslComponent) {
            ForEach(HSLComponent.allCases) { Text(app.t($0.labelKey)).tag($0) }
        }
        .pickerStyle(.segmented)
        ForEach(HSLBand.allCases) { band in
            AdjustmentSlider(labelKey: band.labelKey, value: keyPath(band, editing.hslComponent), range: -1...1, tint: Self.bandColors[band.rawValue])
        }
    }

    private func keyPath(_ band: HSLBand, _ component: HSLComponent) -> WritableKeyPath<EditRecipe, Double> {
        switch component {
        case .hue: \EditRecipe.hsl[band.rawValue].hue
        case .saturation: \EditRecipe.hsl[band.rawValue].saturation
        case .luminance: \EditRecipe.hsl[band.rawValue].luminance
        }
    }
}

struct GeometryPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var editing = app.editing
        PanelHeader(title: app.t("geometry.crop"))
        Picker(app.t("geometry.aspect"), selection: $editing.cropAspect) {
            ForEach(CropAspect.allCases) { Text($0.label).tag($0) }
        }
        Picker(app.t("geometry.guide"), selection: $editing.cropGuide) {
            ForEach(CropGuide.allCases) { Text(app.t($0.labelKey)).tag($0) }
        }
        Button(app.t("geometry.resetCrop")) {
            editing.recipe.crop = CropRect()
            editing.commit("history.crop")
        }

        PanelHeader(title: app.t("geometry.transform"))
        AdjustmentSlider(labelKey: "geometry.straighten", value: \.straighten, range: -45...45)
        HStack {
            Button { rotate(-1) } label: { Image(systemName: "rotate.left") }
            Button { rotate(1) } label: { Image(systemName: "rotate.right") }
            Button {
                editing.recipe.flipHorizontal.toggle()
                editing.commit("history.flip")
            } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
        }
        AdjustmentSlider(labelKey: "geometry.perspectiveV", value: \.perspectiveVertical, range: -1...1)
        AdjustmentSlider(labelKey: "geometry.perspectiveH", value: \.perspectiveHorizontal, range: -1...1)

        PanelHeader(title: app.t("geometry.lens"))
        Toggle(app.t("geometry.lensCorrection"), isOn: Binding(
            get: { editing.recipe.lensCorrection },
            set: {
                editing.recipe.lensCorrection = $0
                editing.commit("geometry.lensCorrection")
            }
        ))
        Text(app.t("geometry.lensHint"))
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
    }

    private func rotate(_ direction: Int) {
        let editing = app.editing
        editing.recipe.quarterTurns = (editing.recipe.quarterTurns + direction + 4) % 4
        editing.recipe.crop = CropRect()
        editing.commit("history.rotate")
    }
}

struct PresetsPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \EditPreset.name) private var presets: [EditPreset]
    let list: [Photo]
    @State private var newName = ""

    var body: some View {
        let editing = app.editing
        HStack {
            TextField(app.t("presets.name"), text: $newName)
                .textFieldStyle(.roundedBorder)
            Button(app.t("presets.save")) {
                guard let data = try? JSONEncoder().encode(editing.recipe) else { return }
                context.insert(EditPreset(name: newName.trimmingCharacters(in: .whitespaces), recipeData: data))
                try? context.save()
                newName = ""
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Text(app.t("presets.hint"))
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)

        if presets.isEmpty {
            Text(app.t("presets.empty")).foregroundStyle(Palette.textSecondary)
        }
        ForEach(presets) { preset in
            HStack {
                Text(preset.name)
                Spacer()
                Button(app.t("presets.apply")) {
                    guard let recipe = try? JSONDecoder().decode(EditRecipe.self, from: preset.recipeData) else { return }
                    let targets = app.culling.targets(in: list)
                    editing.applySettings(recipe, labelKey: "history.preset", to: targets.isEmpty ? list.filter { $0.id == editing.photo?.id } : targets)
                }
                Button(role: .destructive) {
                    context.delete(preset)
                    try? context.save()
                } label: { Image(systemName: "trash") }
            }
            .padding(8)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct HistoryPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let editing = app.editing
        HStack {
            Button(app.t("history.undo")) { editing.undo() }.disabled(!editing.history.canUndo)
            Button(app.t("history.redo")) { editing.redo() }.disabled(!editing.history.canRedo)
        }
        ForEach(Array(editing.history.entries.enumerated()).reversed(), id: \.offset) { index, entry in
            let isCurrent = index == editing.history.index
            HStack(spacing: 8) {
                Circle()
                    .fill(isCurrent ? Brand.orange : (index > editing.history.index ? Palette.separator : Palette.textSecondary))
                    .frame(width: 8, height: 8)
                Text(app.t(entry.labelKey))
                    .foregroundStyle(index > editing.history.index ? Palette.textSecondary : Palette.textPrimary)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(isCurrent ? Brand.orange.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture { editing.jump(to: index) }
        }
    }
}
