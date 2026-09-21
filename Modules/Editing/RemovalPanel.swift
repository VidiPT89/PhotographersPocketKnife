import SwiftUI

/// Remover objetos: clicar num objeto (detetado pelo Vision) ou pintar a zona.
struct RemovalPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var editing = app.editing
        Picker("", selection: $editing.removalMode) {
            ForEach(RemovalMode.allCases) { mode in
                Label(app.t(mode.labelKey), systemImage: mode.icon).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .hint(app.t("removal.modeTitle"))
        Text(app.t(editing.removalMode == .object ? "removal.objectHint" : "removal.brushHint"))
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)

        if editing.removalMode == .brush {
            VStack(spacing: 2) {
                HStack {
                    Text(app.t("mask.brushSize"))
                    Spacer()
                    Text("\(Int(editing.removalBrushSize * 100))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Brand.orange)
                }
                .font(Typography.caption)
                Slider(value: $editing.removalBrushSize, in: 0.01...0.25)
                    .tint(Brand.orange)
            }
        }

        if editing.recipe.removals.isEmpty {
            Text(app.t("removal.empty")).foregroundStyle(Palette.textSecondary)
        }
        ForEach(Array(editing.recipe.removals.enumerated()), id: \.element.id) { index, removal in
            let isObject = removal.objectPoint != nil
            HStack(spacing: 8) {
                Image(systemName: isObject ? "person.crop.square" : "paintbrush.pointed.fill")
                    .foregroundStyle(Brand.orange)
                Text("\(app.t(isObject ? "removal.object" : "removal.painted")) \(index + 1)")
                Spacer()
                Button(role: .destructive) { editing.deleteRemoval(removal.id) } label: { Image(systemName: "trash") }
                    .hint(app.t("common.delete"))
            }
            .padding(8)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 7))
            .appearAnimation()
        }
        if !editing.recipe.removals.isEmpty {
            Button(app.t("removal.clear"), role: .destructive) { editing.clearRemovals() }
        }
    }
}

/// No canvas: clique para escolher um objeto, ou arrastar para pintar a zona a remover.
struct RemovalOverlay: View {
    @Environment(AppState.self) private var app
    let size: CGSize
    @State private var stroke: [CGPoint] = []
    @State private var hover: CGPoint?
    @State private var detecting: CGPoint?

    var body: some View {
        let editing = app.editing
        ZStack(alignment: .topLeading) {
            ForEach(editing.recipe.removals) { removal in
                if let point = removal.objectPoint {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white, Brand.error)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .position(x: point.x * size.width, y: point.y * size.height)
                        .allowsHitTesting(false)
                }
            }
            if !stroke.isEmpty {
                Path { path in
                    path.addLines(stroke.count == 1 ? [stroke[0], CGPoint(x: stroke[0].x + 0.1, y: stroke[0].y)] : stroke)
                }
                .stroke(Brand.error.opacity(0.45), style: StrokeStyle(lineWidth: editing.removalBrushSize * min(size.width, size.height), lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
            }

            if editing.removalMode == .brush {
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(paintGesture)
                    .onContinuousHover { phase in
                        if case .active(let location) = phase { hover = location } else { hover = nil }
                    }
                if let hover {
                    let diameter = editing.removalBrushSize * min(size.width, size.height)
                    Circle()
                        .stroke(Color.black.opacity(0.45), lineWidth: 2.5)
                        .overlay(Circle().stroke(Color.white.opacity(0.95), lineWidth: 1))
                        .frame(width: diameter, height: diameter)
                        .position(hover)
                        .allowsHitTesting(false)
                }
            } else {
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in pick(location) }
                    .onHover { inside in
                        if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                    }
            }

            if let detecting {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .position(detecting)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    private var paintGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                hover = value.location
                if let last = stroke.last, hypot(last.x - value.location.x, last.y - value.location.y) < 2 { return }
                stroke.append(value.location)
            }
            .onEnded { _ in
                let points = stroke.map { CurvePoint(x: min(max($0.x / size.width, 0), 1), y: min(max($0.y / size.height, 0), 1)) }
                stroke = []
                guard !points.isEmpty else { return }
                app.editing.addRemoval(Removal(strokes: [BrushStroke(points: points, size: app.editing.removalBrushSize)]))
            }
    }

    private func pick(_ location: CGPoint) {
        guard detecting == nil else { return }
        detecting = location
        let point = CurvePoint(x: min(max(location.x / size.width, 0), 1), y: min(max(location.y / size.height, 0), 1))
        Task {
            let found = await app.editing.pickObject(at: point)
            detecting = nil
            if !found {
                app.showToast(app.t("removal.noObject"), icon: "questionmark.circle.fill")
            }
        }
    }
}
