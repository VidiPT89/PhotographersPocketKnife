import SwiftUI

extension ColorLabel {
    var color: Color? {
        switch self {
        case .none: nil
        case .red: Brand.error
        case .yellow: Color(hex: 0xF2C94C)
        case .green: Brand.success
        case .blue: Color(hex: 0x3B82F6)
        case .purple: Color(hex: 0x9B6BDF)
        }
    }
}

/// Thumbnail assíncrona. Mostra primeiro uma versão pequena e depois a grande.
/// Se a foto tiver uma receita de edição, mostra a versão editada.
struct ThumbnailView: View {
    let url: URL
    let maxPixel: Int
    var recipeData: Data?
    var fit = false

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: fit ? .fit : .fill)
                    .transition(.opacity)
            } else {
                Rectangle().fill(Palette.separator.opacity(0.4))
                ProgressView().controlSize(.small)
            }
        }
        .frame(minWidth: 0, minHeight: 0)
        .clipped()
        .task(id: "\(url.path)|\(maxPixel)|\(recipeData?.hashValue ?? 0)") {
            await load()
        }
    }

    private func load() async {
        let url = url, maxPixel = maxPixel, recipeData = recipeData
        if let hit = ThumbnailCache.shared.memoryHit(for: url, maxPixel: min(maxPixel, 320)), recipeData == nil || image == nil {
            image = hit.cgImage
        }
        if maxPixel > 320, image == nil {
            image = await Task.detached(priority: .userInitiated) {
                ThumbnailCache.shared.thumbnail(for: url, maxPixel: 320)
            }.value?.cgImage
        }
        let final = await Task.detached(priority: .userInitiated) { () -> SendableImage? in
            if let recipeData, let recipe = try? JSONDecoder().decode(EditRecipe.self, from: recipeData), !recipe.isIdentity {
                return ImageRenderer.shared.renderPreview(url: url, recipe: recipe, maxPixel: maxPixel)
            }
            return ThumbnailCache.shared.thumbnail(for: url, maxPixel: maxPixel)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) { image = final?.cgImage }
    }
}

struct StarRating: View {
    let rating: Int
    var size: CGFloat = 11
    var onChange: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { index in
                let filled = index <= rating
                Image(systemName: filled ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(filled ? Brand.orange : Palette.textSecondary.opacity(0.45))
                    .scaleEffect(filled ? 1 : 0.85)
                    .symbolEffect(.bounce, value: filled)
                    .animation(Motion.pop.delay(Double(index) * 0.03), value: rating)
                    .onTapGesture { onChange?(index == rating ? 0 : index) }
                    .allowsHitTesting(onChange != nil)
            }
        }
    }
}

struct FlagBadge: View {
    let flag: PhotoFlag

    var body: some View {
        switch flag {
        case .pick:
            Image(systemName: "flag.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Brand.success)
                .transition(.scale.combined(with: .opacity))
        case .reject:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Brand.error)
                .transition(.scale.combined(with: .opacity))
        case .none:
            EmptyView()
        }
    }
}

struct HistogramView: View {
    let data: HistogramData?

    var body: some View {
        Canvas { context, size in
            guard let data else { return }
            func path(_ bins: [Float]) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (i, value) in bins.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(max(bins.count - 1, 1))
                    path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(value))))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                return path
            }
            context.fill(path(data.luma), with: .color(.gray.opacity(0.35)))
            context.blendMode = .plusLighter
            context.fill(path(data.red), with: .color(.red.opacity(0.45)))
            context.fill(path(data.green), with: .color(.green.opacity(0.45)))
            context.fill(path(data.blue), with: .color(.blue.opacity(0.45)))
        }
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .animation(Motion.smooth, value: data)
    }
}
