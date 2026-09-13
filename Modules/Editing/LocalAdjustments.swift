import SwiftUI

/// Gradação de cor: três rodas (sombras, meios-tons, altas luzes) e equilíbrio.
struct ColorGradingPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let editing = app.editing
        HStack(alignment: .top, spacing: 8) {
            ColorWheel(titleKey: "grading.shadows", hue: \.shadowsHue, saturation: \.shadowsSaturation)
            ColorWheel(titleKey: "grading.midtones", hue: \.midtonesHue, saturation: \.midtonesSaturation)
            ColorWheel(titleKey: "grading.highlights", hue: \.highlightsHue, saturation: \.highlightsSaturation)
        }
        AdjustmentSlider(labelKey: "grading.balance", value: \.gradingBalance, range: -1...1)
        Text(app.t("grading.hint"))
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
        Button(app.t("grading.reset")) {
            editing.recipe.shadowsSaturation = 0
            editing.recipe.midtonesSaturation = 0
            editing.recipe.highlightsSaturation = 0
            editing.recipe.gradingBalance = 0
            editing.commit("editTab.grading")
        }
    }
}

struct ColorWheel: View {
    @Environment(AppState.self) private var app
    let titleKey: String
    let hue: WritableKeyPath<EditRecipe, Double>
    let saturation: WritableKeyPath<EditRecipe, Double>
    @State private var dragging = false

    private static let hues: [Color] = stride(from: 0.0, through: 360.0, by: 30).map { Color(hue: $0 / 360, saturation: 0.9, brightness: 1) }

    var body: some View {
        let editing = app.editing
        let h = editing.recipe[keyPath: hue]
        let s = editing.recipe[keyPath: saturation]
        VStack(spacing: 4) {
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                let radius = size / 2
                let angle = h * .pi / 180
                ZStack {
                    Circle().fill(AngularGradient(colors: Self.hues, center: .center))
                    Circle().fill(RadialGradient(colors: [Color(white: 0.55), Color(white: 0.55).opacity(0)], center: .center, startRadius: 0, endRadius: radius))
                    Circle().stroke(Palette.separator, lineWidth: 1)
                    Circle()
                        .fill(.white)
                        .frame(width: dragging ? 16 : 12, height: dragging ? 16 : 12)
                        .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 1))
                        .shadow(color: Brand.orange.opacity(dragging ? 0.8 : 0.3), radius: dragging ? 6 : 2)
                        .position(x: radius + cos(angle) * s * radius, y: radius + sin(angle) * s * radius)
                        .animation(Motion.snappy, value: dragging)
                }
                .frame(width: size, height: size)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = true
                            let dx = value.location.x - radius, dy = value.location.y - radius
                            var degrees = atan2(dy, dx) * 180 / .pi
                            if degrees < 0 { degrees += 360 }
                            editing.recipe[keyPath: hue] = degrees
                            editing.recipe[keyPath: saturation] = min(hypot(dx, dy) / radius, 1)
                            editing.scheduleRender()
                        }
                        .onEnded { _ in
                            dragging = false
                            editing.commit("editTab.grading")
                        }
                )
            }
            .aspectRatio(1, contentMode: .fit)
            Text(app.t(titleKey))
                .font(.system(size: 10, weight: .semibold))
                .onTapGesture(count: 2) {
                    editing.recipe[keyPath: saturation] = 0
                    editing.commit("editTab.grading")
                }
            Text(s > 0.005 ? "\(Int(h))° · \(Int(s * 100))%" : "—")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(s > 0.005 ? Brand.orange : Palette.textSecondary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
    }
}

/// Máscaras locais (gradiente linear ou radial) com ajustes próprios.
struct MasksPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let editing = app.editing
        HStack {
            ForEach(MaskKind.allCases) { kind in
                Button { editing.addMask(kind) } label: {
                    Label(app.t(kind.labelKey), systemImage: kind.icon)
                }
            }
        }
        Text(app.t("mask.hint"))
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
        if editing.recipe.masks.isEmpty {
            Text(app.t("mask.empty")).foregroundStyle(Palette.textSecondary)
        }
        ForEach(Array(editing.recipe.masks.enumerated()), id: \.element.id) { index, mask in
            let selected = editing.selectedMaskID == mask.id
            HStack(spacing: 8) {
                Image(systemName: mask.kind.icon).foregroundStyle(selected ? Brand.orange : Palette.textSecondary)
                Text("\(app.t(mask.kind.labelKey)) \(index + 1)")
                Spacer()
                Button {
                    editing.recipe.masks[index].invert.toggle()
                    editing.commit("history.mask")
                } label: { Image(systemName: mask.invert ? "circle.righthalf.filled" : "circle.lefthalf.filled") }
                .help(app.t("mask.invert"))
                Button(role: .destructive) { editing.deleteMask(mask.id) } label: { Image(systemName: "trash") }
            }
            .padding(8)
            .background(selected ? Brand.orange.opacity(0.14) : Palette.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Brand.orange : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Motion.snappy) { editing.selectedMaskID = mask.id } }
            .appearAnimation()
        }
        if let index = editing.selectedMaskIndex {
            CollapsibleSection(title: app.t("mask.adjustments")) {
                AdjustmentSlider(labelKey: "adjust.exposure", value: \EditRecipe.masks[index].exposure, range: -3...3)
                AdjustmentSlider(labelKey: "adjust.contrast", value: \EditRecipe.masks[index].contrast, range: -1...1)
                AdjustmentSlider(labelKey: "adjust.saturation", value: \EditRecipe.masks[index].saturation, range: -1...1)
                AdjustmentSlider(labelKey: "adjust.temperature", value: \EditRecipe.masks[index].temperature, range: -1...1)
                AdjustmentSlider(labelKey: "adjust.clarity", value: \EditRecipe.masks[index].clarity, range: -1...1)
                if editing.recipe.masks[index].kind == .radial {
                    AdjustmentSlider(labelKey: "mask.feather", value: \EditRecipe.masks[index].feather, range: 0...1, defaultValue: 0.5)
                }
            }
            .id(editing.selectedMaskID)
        }
    }
}

/// Pegas no canvas para mover e redimensionar a máscara selecionada.
struct MaskOverlay: View {
    @Environment(AppState.self) private var app
    let size: CGSize
    @State private var dragStart: LocalMask?

    var body: some View {
        let editing = app.editing
        ZStack(alignment: .topLeading) {
            ForEach(editing.recipe.masks) { mask in
                if mask.id != editing.selectedMaskID {
                    Circle()
                        .fill(Palette.textSecondary)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .frame(width: 11, height: 11)
                        .position(pin(for: mask))
                        .onTapGesture { withAnimation(Motion.snappy) { editing.selectedMaskID = mask.id } }
                }
            }
            if let index = editing.selectedMaskIndex {
                let mask = editing.recipe.masks[index]
                switch mask.kind {
                case .radial:
                    let center = CGPoint(x: mask.centerX * size.width, y: mask.centerY * size.height)
                    let rx = mask.radiusX * size.width, ry = mask.radiusY * size.height
                    Ellipse()
                        .stroke(Brand.orange, lineWidth: 1.5)
                        .frame(width: rx * 2, height: ry * 2)
                        .position(center)
                        .allowsHitTesting(false)
                    Ellipse()
                        .stroke(Brand.amber.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .frame(width: rx * 2 * (1 - mask.feather), height: ry * 2 * (1 - mask.feather))
                        .position(center)
                        .allowsHitTesting(false)
                    handle(at: center) { t, start in
                        var m = start
                        m.centerX = min(max(start.centerX + t.width / size.width, 0), 1)
                        m.centerY = min(max(start.centerY + t.height / size.height, 0), 1)
                        return m
                    }
                    handle(at: CGPoint(x: center.x + rx, y: center.y)) { t, start in
                        var m = start
                        m.radiusX = max(start.radiusX + t.width / size.width, 0.02)
                        return m
                    }
                    handle(at: CGPoint(x: center.x, y: center.y + ry)) { t, start in
                        var m = start
                        m.radiusY = max(start.radiusY + t.height / size.height, 0.02)
                        return m
                    }
                case .linear:
                    let start = CGPoint(x: mask.startX * size.width, y: mask.startY * size.height)
                    let end = CGPoint(x: mask.endX * size.width, y: mask.endY * size.height)
                    LinearMaskGuides(start: start, end: end)
                        .stroke(Brand.orange, style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                        .allowsHitTesting(false)
                    handle(at: start) { t, s in
                        var m = s
                        m.startX = min(max(s.startX + t.width / size.width, 0), 1)
                        m.startY = min(max(s.startY + t.height / size.height, 0), 1)
                        return m
                    }
                    handle(at: end) { t, s in
                        var m = s
                        m.endX = min(max(s.endX + t.width / size.width, 0), 1)
                        m.endY = min(max(s.endY + t.height / size.height, 0), 1)
                        return m
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    private func pin(for mask: LocalMask) -> CGPoint {
        switch mask.kind {
        case .radial: CGPoint(x: mask.centerX * size.width, y: mask.centerY * size.height)
        case .linear: CGPoint(x: mask.startX * size.width, y: mask.startY * size.height)
        }
    }

    private func handle(at point: CGPoint, update: @escaping (CGSize, LocalMask) -> LocalMask) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(Brand.orange, lineWidth: 2))
            .shadow(color: .black.opacity(0.4), radius: 2)
            .position(point)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard let index = app.editing.selectedMaskIndex else { return }
                        let start = dragStart ?? app.editing.recipe.masks[index]
                        dragStart = start
                        app.editing.recipe.masks[index] = update(value.translation, start)
                        app.editing.scheduleRender()
                    }
                    .onEnded { _ in
                        dragStart = nil
                        app.editing.commit("history.mask")
                    }
            )
    }
}

/// Linha entre os dois pontos do gradiente e as perpendiculares onde começa e acaba o efeito.
private struct LinearMaskGuides: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let perpendicular = CGPoint(x: -dy / length * 2000, y: dx / length * 2000)
        for point in [start, end] {
            path.move(to: CGPoint(x: point.x - perpendicular.x, y: point.y - perpendicular.y))
            path.addLine(to: CGPoint(x: point.x + perpendicular.x, y: point.y + perpendicular.y))
        }
        return path
    }
}

/// Indicador de recorte no canto do histograma (clicar mostra as zonas na imagem).
struct ClippingIndicator: View {
    @Environment(AppState.self) private var app
    let clipped: Bool
    let color: Color
    let isOn: Bool
    let helpKey: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "triangle.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(clipped ? color : Color.white.opacity(0.35))
                .padding(4)
                .background(Circle().fill(isOn ? color.opacity(0.3) : .clear))
                .shadow(color: clipped ? color.opacity(0.8) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
        .help(app.t(helpKey))
        .padding(3)
        .animation(Motion.snappy, value: clipped)
    }
}

/// Reflexo de luz diagonal sobre a imagem quando se aplica um preset.
struct PresetSweep: View {
    let trigger: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = -0.5
    @State private var visible = false

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.5), Brand.amber.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.45, height: geo.size.height * 2.2)
                .rotationEffect(.degrees(20))
                .offset(x: progress * geo.size.width * 1.5, y: -geo.size.height * 0.6)
                .opacity(visible ? 1 : 0)
        }
        .clipped()
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            guard !reduceMotion else { return }
            progress = -0.5
            visible = true
            withAnimation(.easeInOut(duration: 0.35)) { progress = 1.1 }
            Task {
                try? await Task.sleep(for: .milliseconds(380))
                visible = false
            }
        }
    }
}
