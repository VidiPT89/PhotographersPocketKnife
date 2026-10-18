import SwiftUI

struct EditCanvas: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let editing = app.editing
        GeometryReader { geo in
            ZStack {
                Palette.canvas
                if let preview = editing.preview {
                    let rect = fittedSize(CGSize(width: preview.width, height: preview.height), in: geo.size, padding: 24)
                    ZStack(alignment: .topLeading) {
                        canvasImage(preview: preview, size: rect)
                        if editing.showClipping, editing.compareMode != .before, let clipping = editing.clippingOverlay {
                            Image(decorative: clipping, scale: 1)
                                .resizable()
                                .frame(width: rect.width, height: rect.height)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                        PresetSweep(trigger: editing.presetFlash)
                            .frame(width: rect.width, height: rect.height)
                        if editing.isCropping {
                            CropOverlay(size: rect)
                        }
                        if editing.tab == .masks {
                            MaskOverlay(size: rect)
                                .transition(.opacity)
                        }
                        if editing.tab == .remove, editing.compareMode == .off {
                            RemovalOverlay(size: rect)
                                .transition(.opacity)
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
                    .fill(Brand.amber)
                    .frame(width: 2)
                    .offset(x: size.width * editing.splitPosition - 1)
                    .shadow(color: Brand.amber, radius: 6)
                Circle()
                    .fill(Brand.amber)
                    .frame(width: 26, height: 26)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Brand.black))
                    .shadow(color: Brand.amber.opacity(0.7), radius: 8)
                    .offset(x: size.width * editing.splitPosition - 13, y: size.height / 2 - 13)
                    .frame(maxHeight: .infinity, alignment: .top)
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
        .onChange(of: app.editing.cropAspect) { _, aspect in
            // Ao escolher um rácio, o recorte atual passa logo a respeitá-lo.
            guard let normalized = normalizedAspect(aspect) else { return }
            let crop = app.editing.recipe.crop
            guard abs(crop.width / crop.height - normalized) > 0.001 else { return }
            app.editing.recipe.crop = crop.fitted(aspect: normalized)
            app.editing.commit("history.crop")
        }
    }

    /// Converte o rácio em píxeis para coordenadas normalizadas da imagem.
    private func normalizedAspect(_ aspect: CropAspect) -> Double? {
        aspect.ratio.map { $0 * size.height / max(size.width, 1) }
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
                app.editing.recipe.crop = CropRect.resized(
                    start,
                    movingRight: corner == .topRight || corner == .bottomRight,
                    movingBottom: corner == .bottomLeft || corner == .bottomRight,
                    dx: value.translation.width / size.width,
                    dy: value.translation.height / size.height,
                    aspect: normalizedAspect(app.editing.cropAspect)
                )
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
