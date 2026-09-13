import SwiftUI
import SwiftData

struct LoupeView: View {
    @Environment(AppState.self) private var app
    let list: [Photo]

    var body: some View {
        if let photo = app.culling.focused(in: list) ?? list.first {
            VStack(spacing: 0) {
                LoupeCanvas(photo: photo)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
                    .background(Palette.canvas)
                PhotoCaptionBar(photo: photo)
                FilmStrip(list: list)
            }
            .animation(Motion.smooth, value: photo.id)
            .onAppear { if app.culling.focusedID == nil { app.culling.focusedID = photo.id } }
            .task(id: photo.id) { prefetch(around: photo) }
        } else {
            EmptyModuleView(systemImage: "rectangle", title: app.t("filter.noResults"), subtitle: "")
        }
    }

    /// Prepara n+1…n+8 e n−1…n−4 (invertido se a navegação vai para trás), para a foto seguinte aparecer já.
    private func prefetch(around photo: Photo) {
        guard let index = list.firstIndex(where: { $0.id == photo.id }) else { return }
        let forward = app.culling.lastDirection >= 0
        let ahead = forward ? 8 : 4, behind = forward ? 4 : 8
        let order = (1...ahead).map { index + $0 } + (1...behind).map { index - $0 }
        let urls = order.filter { list.indices.contains($0) }.map { list[$0].url }
        Task.detached(priority: .utility) {
            for url in urls where !Task.isCancelled {
                _ = ThumbnailCache.shared.thumbnail(for: url, maxPixel: 2400)
            }
        }
    }
}

/// Visor com zoom 100 % (`Z`) e lupa circular (`L`) que seguem o cursor.
struct LoupeCanvas: View {
    @Environment(AppState.self) private var app
    @Environment(\.displayScale) private var displayScale
    let photo: Photo

    @State private var hover: CGPoint?
    @State private var fullImage: CGImage?

    var body: some View {
        let culling = app.culling
        GeometryReader { geo in
            ZStack {
                if culling.zoomed, let fullImage {
                    zoomed(fullImage, in: geo.size)
                        .transition(.opacity)
                } else {
                    ThumbnailView(url: photo.url, maxPixel: 2400, recipeData: photo.recipeData, fit: true)
                        .transition(.opacity)
                }
                if culling.magnifier, !culling.zoomed, let fullImage, let hover {
                    magnifier(fullImage, at: hover, in: geo.size)
                }
                if (culling.zoomed || culling.magnifier), fullImage == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hover = location
                case .ended: hover = nil
                }
            }
            .onTapGesture(count: 2) {
                withAnimation(Motion.snappy) { culling.perform(.zoom, in: []) }
            }
            .animation(Motion.snappy, value: culling.zoomed)
        }
        .overlay(alignment: .topTrailing) {
            if culling.zoomed || culling.magnifier {
                Text(culling.zoomed ? "100 %" : app.t("shortcut.magnifier"))
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Brand.orange.opacity(0.6), lineWidth: 1))
                    .padding(10)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .task(id: "\(photo.id)|\(culling.zoomed || culling.magnifier)") {
            guard culling.zoomed || culling.magnifier else { return }
            fullImage = nil
            let url = photo.url
            let longest = max(photo.pixelWidth, photo.pixelHeight, 2400)
            fullImage = await Task.detached(priority: .userInitiated) {
                ThumbnailCache.generate(url: url, maxPixel: longest).map { SendableImage(cgImage: $0) }
            }.value?.cgImage
        }
    }

    private func fitRect(_ image: CGImage, in size: CGSize) -> CGRect {
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// Ponto do cursor normalizado dentro da imagem ajustada ao ecrã (0…1).
    private func normalized(_ point: CGPoint, _ image: CGImage, in size: CGSize) -> CGPoint {
        let fit = fitRect(image, in: size)
        return CGPoint(
            x: min(max((point.x - fit.minX) / fit.width, 0), 1),
            y: min(max((point.y - fit.minY) / fit.height, 0), 1)
        )
    }

    private func zoomed(_ image: CGImage, in size: CGSize) -> some View {
        let width = CGFloat(image.width) / displayScale
        let height = CGFloat(image.height) / displayScale
        let cursor = hover ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let n = normalized(cursor, image, in: size)
        var x = cursor.x - n.x * width
        var y = cursor.y - n.y * height
        x = width > size.width ? min(0, max(size.width - width, x)) : (size.width - width) / 2
        y = height > size.height ? min(0, max(size.height - height, y)) : (size.height - height) / 2
        return Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: width, height: height)
            .position(x: x + width / 2, y: y + height / 2)
    }

    private func magnifier(_ image: CGImage, at point: CGPoint, in size: CGSize) -> some View {
        let diameter: CGFloat = 230
        let width = CGFloat(image.width) / displayScale
        let height = CGFloat(image.height) / displayScale
        let n = normalized(point, image, in: size)
        return Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: width, height: height)
            .offset(x: diameter / 2 - n.x * width, y: diameter / 2 - n.y * height)
            .frame(width: diameter, height: diameter, alignment: .topLeading)
            .clipShape(Circle())
            .overlay(Circle().stroke(Brand.diagonal, lineWidth: 3))
            .shadow(color: .black.opacity(0.5), radius: 16)
            .position(point)
            .allowsHitTesting(false)
    }
}

/// Comparação de 2 ou 4 fotos com zoom e pan sincronizados (pinch/scroll + arrastar, duplo clique repõe).
struct CompareView: View {
    @Environment(AppState.self) private var app
    let list: [Photo]

    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero

    var body: some View {
        let photos = app.culling.comparePhotos(in: list)
        let columns = photos.count <= 2 ? max(photos.count, 1) : 2
        GeometryReader { geo in
            let rows = CGFloat((photos.count + columns - 1) / columns)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(photos) { photo in
                    let focused = app.culling.focusedID == photo.id
                    VStack(spacing: 0) {
                        ThumbnailView(url: photo.url, maxPixel: zoom > 1.5 ? 3200 : 1600, recipeData: photo.recipeData, fit: true)
                            .scaleEffect(zoom)
                            .offset(pan)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .padding(8)
                            .background(Palette.canvas)
                        PhotoCaptionBar(photo: photo)
                    }
                    .frame(height: max(120, (geo.size.height - 8 * (rows - 1) - 24) / max(rows, 1)))
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Brand.orange : .clear, lineWidth: 2))
                    .contentShape(Rectangle())
                    .onTapGesture { app.culling.focusedID = photo.id }
                }
            }
            .padding(12)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in zoom = min(max(baseZoom * value.magnification, 1), 8) }
                    .onEnded { _ in
                        baseZoom = zoom
                        if zoom <= 1 { resetPan() }
                    }
                    .simultaneously(with: DragGesture()
                        .onChanged { value in
                            guard zoom > 1 else { return }
                            pan = CGSize(width: basePan.width + value.translation.width, height: basePan.height + value.translation.height)
                        }
                        .onEnded { _ in basePan = pan })
            )
            .onTapGesture(count: 2) { reset() }
        }
        .overlay(alignment: .topTrailing) {
            if zoom > 1 {
                Button { reset() } label: {
                    Label("\(Int(zoom * 100)) %", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .help(app.t("compare.zoomReset"))
                .padding(18)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: zoom > 1)
    }

    private func reset() {
        withAnimation(Motion.snappy) {
            zoom = 1
            baseZoom = 1
            resetPan()
        }
    }

    private func resetPan() {
        pan = .zero
        basePan = .zero
    }
}

/// Modo apresentação ao cliente: ecrã completo, fundo preto, só a foto.
struct PresentationView: View {
    @Environment(AppState.self) private var app
    @Query(sort: \Photo.importedAt) private var photos: [Photo]
    @FocusState private var focus: Bool
    @State private var enteredFullScreen = false

    var body: some View {
        let list = app.culling.visible(photos)
        let photo = app.culling.focused(in: list) ?? list.first
        ZStack {
            Color.black.ignoresSafeArea()
            if let photo {
                ThumbnailView(url: photo.url, maxPixel: 2400, recipeData: photo.recipeData, fit: true)
                    .padding(28)
                    .id(photo.id)
                    .transition(.opacity)
                VStack {
                    HStack {
                        Spacer()
                        Text(app.t("presentation.exit"))
                            .font(Typography.caption)
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(16)
                    }
                    Spacer()
                    PhotoCaptionBar(photo: photo)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: 640)
                        .padding(.bottom, 24)
                }
                .environment(\.colorScheme, .dark)
            }
        }
        .animation(Motion.smooth, value: photo?.id)
        .focusable()
        .focusEffectDisabled()
        .focused($focus)
        .onAppear {
            focus = true
            if let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                enteredFullScreen = true
            }
        }
        .onDisappear {
            if enteredFullScreen, let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .escape:
                close()
                return .handled
            case .leftArrow:
                app.culling.move(by: -1, in: list, extend: false)
                return .handled
            case .rightArrow, .space:
                app.culling.move(by: 1, in: list, extend: false)
                return .handled
            default:
                break
            }
            guard let action = app.shortcuts.action(for: press.characters) else { return .ignored }
            if action == .presentation {
                close()
                return .handled
            }
            guard action.showsToast else { return .ignored }
            withAnimation(Motion.pop) { app.culling.perform(action, in: list) }
            return .handled
        }
    }

    private func close() {
        withAnimation(Motion.smooth) { app.culling.presenting = false }
    }
}

struct PhotoCaptionBar: View {
    @Environment(AppState.self) private var app
    let photo: Photo

    var body: some View {
        HStack(spacing: 10) {
            Text(photo.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1)
            StarRating(rating: photo.rating, size: 12) { photo.rating = $0 }
            FlagBadge(flag: photo.flag)
            if let color = photo.colorLabel.color {
                Circle().fill(color).frame(width: 10, height: 10)
            }
            Spacer()
            Text(exposureSummary)
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var exposureSummary: String {
        [
            photo.camera,
            photo.lens,
            photo.focalLength.map { "\(Int($0.rounded())) mm" },
            photo.aperture.map { String(format: "f/%.1f", $0) },
            photo.iso.map { "ISO \($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

struct FilmStrip: View {
    @Environment(AppState.self) private var app
    let list: [Photo]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(list) { photo in
                        let focused = app.culling.focusedID == photo.id
                        ThumbnailView(url: photo.url, maxPixel: 320, recipeData: photo.recipeData)
                            .frame(width: 96, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused ? Brand.orange : .clear, lineWidth: 2))
                            .scaleEffect(focused ? 1.04 : 1)
                            .opacity(photo.flag == .reject ? 0.45 : 1)
                            .id(photo.id)
                            .onTapGesture { app.culling.click(photo, in: list) }
                            .animation(Motion.snappy, value: focused)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: 84)
            .background(Palette.panel)
            .onChange(of: app.culling.focusedID) { _, id in
                guard let id else { return }
                withAnimation(Motion.smooth) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}
