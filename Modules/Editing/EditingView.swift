import SwiftUI
import SwiftData

struct EditingView: View {
    @Environment(AppState.self) private var app
    @Query(sort: \Photo.importedAt) private var photos: [Photo]
    @State private var showExport = false

    var body: some View {
        let list = app.culling.visible(photos)
        let photo = app.culling.focused(in: list) ?? app.culling.targets(in: list).first ?? list.first

        if let photo {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    EditingToolbar(list: list, showExport: $showExport)
                    Divider()
                    EditCanvas()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    FilmStrip(list: list)
                }
                Divider()
                AdjustmentPanel(list: list)
                    .frame(width: 300)
            }
            .task(id: "\(photo.id)|\(photo.path)") { app.editing.load(photo) }
            .sheet(isPresented: $showExport) {
                ExportSheet(photos: app.culling.targets(in: list).isEmpty ? [photo] : app.culling.targets(in: list))
            }
            .onReceive(NotificationCenter.default.publisher(for: .showExport)) { _ in showExport = true }
        } else {
            EmptyModuleView(
                systemImage: "slider.horizontal.3",
                title: app.t("editing.empty.title"),
                subtitle: app.t("editing.empty.subtitle")
            )
        }
    }
}

extension Notification.Name {
    static let showExport = Notification.Name("PhotographersPocketKnife.showExport")
}

struct EditingToolbar: View {
    @Environment(AppState.self) private var app
    let list: [Photo]
    @Binding var showExport: Bool

    var body: some View {
        @Bindable var editing = app.editing
        HStack(spacing: 10) {
            Button { editing.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!editing.history.canUndo)
                .help(app.t("history.undo"))
            Button { editing.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!editing.history.canRedo)
                .help(app.t("history.redo"))

            Picker("", selection: $editing.compareMode) {
                ForEach(CompareMode.allCases) { Text(app.t($0.labelKey)).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Spacer()

            Button(app.t("editing.copy")) { editing.copySettings() }
            Button(app.t("editing.paste")) {
                guard let clipboard = editing.clipboard else { return }
                editing.applySettings(clipboard, labelKey: "history.paste", to: app.culling.targets(in: list))
            }
            .disabled(editing.clipboard == nil)
            Button(app.t("editing.reset")) { editing.reset() }

            PrimaryButton(title: app.t("export.title"), systemImage: "square.and.arrow.up") { showExport = true }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct EditCanvas: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let editing = app.editing
        GeometryReader { geo in
            ZStack {
                Palette.background
                if let preview = editing.preview {
                    let rect = fittedSize(CGSize(width: preview.width, height: preview.height), in: geo.size, padding: 24)
                    ZStack(alignment: .topLeading) {
                        canvasImage(preview: preview, size: rect)
                        if editing.isCropping {
                            CropOverlay(size: rect)
                        }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .shadow(color: .black.opacity(0.35), radius: 12)
                } else {
                    ProgressView()
                }
                if editing.isRendering {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
    }

    @ViewBuilder
    private func canvasImage(preview: CGImage, size: CGSize) -> some View {
        let editing = app.editing
        switch editing.compareMode {
        case .before where editing.beforeImage != nil:
            Image(decorative: editing.beforeImage!, scale: 1).resizable()
                .frame(width: size.width, height: size.height)
        case .split where editing.beforeImage != nil:
            ZStack(alignment: .leading) {
                Image(decorative: preview, scale: 1).resizable()
                Image(decorative: editing.beforeImage!, scale: 1).resizable()
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: size.width * editing.splitPosition)
                    }
                Rectangle()
                    .fill(Brand.orange)
                    .frame(width: 2)
                    .offset(x: size.width * editing.splitPosition - 1)
                    .shadow(color: Brand.orange, radius: 4)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                app.editing.splitPosition = min(max(value.location.x / size.width, 0), 1)
            })
        default:
            Image(decorative: preview, scale: 1).resizable()
                .frame(width: size.width, height: size.height)
        }
    }

    private func fittedSize(_ image: CGSize, in container: CGSize, padding: CGFloat) -> CGSize {
        let available = CGSize(width: max(container.width - padding * 2, 10), height: max(container.height - padding * 2, 10))
        let scale = min(available.width / max(image.width, 1), available.height / max(image.height, 1))
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

struct CropOverlay: View {
    @Environment(AppState.self) private var app
    let size: CGSize
    @State private var dragStart: CropRect?

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        let crop = app.editing.recipe.crop
        let rect = CGRect(x: crop.x * size.width, y: crop.y * size.height, width: crop.width * size.width, height: crop.height * size.height)

        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            CropGuideShape(guide: app.editing.cropGuide)
                .stroke(.white.opacity(0.65), lineWidth: 0.7)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)

            Rectangle()
                .stroke(Brand.orange, lineWidth: 1.5)
                .contentShape(Rectangle())
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .gesture(moveGesture)

            ForEach(Corner.allCases, id: \.self) { corner in
                Circle()
                    .fill(Brand.orange)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .position(position(of: corner, in: rect))
                    .gesture(resizeGesture(corner))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func position(of corner: Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? app.editing.recipe.crop
                dragStart = start
                var crop = start
                crop.x = min(max(start.x + value.translation.width / size.width, 0), 1 - start.width)
                crop.y = min(max(start.y + value.translation.height / size.height, 0), 1 - start.height)
                app.editing.recipe.crop = crop
            }
            .onEnded { _ in
                dragStart = nil
                app.editing.commit("history.crop")
            }
    }

    private func resizeGesture(_ corner: Corner) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? app.editing.recipe.crop
                dragStart = start
                let dx = value.translation.width / size.width
                let dy = value.translation.height / size.height
                let minSize = 0.05
                var left = start.x, top = start.y, right = start.x + start.width, bottom = start.y + start.height
                switch corner {
                case .topLeft: left += dx; top += dy
                case .topRight: right += dx; top += dy
                case .bottomLeft: left += dx; bottom += dy
                case .bottomRight: right += dx; bottom += dy
                }
                left = min(max(left, 0), right - minSize)
                right = max(min(right, 1), left + minSize)
                top = min(max(top, 0), bottom - minSize)
                bottom = max(min(bottom, 1), top + minSize)

                if let ratio = app.editing.cropAspect.ratio {
                    // Converte o rácio em píxeis para coordenadas normalizadas.
                    let height = (right - left) * size.width / (ratio * size.height)
                    switch corner {
                    case .topLeft, .topRight: top = max(bottom - height, 0)
                    case .bottomLeft, .bottomRight: bottom = min(top + height, 1)
                    }
                }
                app.editing.recipe.crop = CropRect(x: left, y: top, width: right - left, height: bottom - top)
            }
            .onEnded { _ in
                dragStart = nil
                app.editing.commit("history.crop")
            }
    }
}

struct CropGuideShape: Shape {
    let guide: CropGuide

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch guide {
        case .none:
            break
        case .thirds:
            for f in [1.0 / 3, 2.0 / 3] {
                path.move(to: CGPoint(x: rect.minX + rect.width * f, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + rect.width * f, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * f))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * f))
            }
        case .golden:
            var r = rect
            for step in 0..<10 {
                guard r.width > 1, r.height > 1 else { break }
                switch step % 4 {
                case 0:
                    let side = min(r.height, r.width)
                    path.addArc(center: CGPoint(x: r.minX + side, y: r.minY + side), radius: side, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
                    r = CGRect(x: r.minX + side, y: r.minY, width: r.width - side, height: r.height)
                case 1:
                    let side = min(r.width, r.height)
                    path.move(to: CGPoint(x: r.minX, y: r.minY))
                    path.addArc(center: CGPoint(x: r.minX, y: r.minY + side), radius: side, startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
                    r = CGRect(x: r.minX, y: r.minY + side, width: r.width, height: r.height - side)
                case 2:
                    let side = min(r.height, r.width)
                    path.move(to: CGPoint(x: r.maxX, y: r.minY))
                    path.addArc(center: CGPoint(x: r.maxX - side, y: r.minY), radius: side, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
                    r = CGRect(x: r.minX, y: r.minY, width: r.width - side, height: r.height)
                default:
                    let side = min(r.width, r.height)
                    path.move(to: CGPoint(x: r.maxX, y: r.maxY))
                    path.addArc(center: CGPoint(x: r.maxX, y: r.maxY - side), radius: side, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
                    r = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - side)
                }
            }
        }
        return path
    }
}
