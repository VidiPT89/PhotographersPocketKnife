import SwiftUI

struct InfoPanel: View {
    @Environment(AppState.self) private var app
    let photo: Photo?

    @State private var fields: [MetadataField] = []
    @State private var histogram: HistogramData?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PanelHeader(title: app.t("info.histogram"))
                HistogramView(data: histogram)
                    .frame(height: 90)

                PanelHeader(title: app.t("info.metadata"))
                if photo == nil {
                    Text(app.t("info.noSelection"))
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                }
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.t(field.id))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                        Text(field.value)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.panel)
        .task(id: photo.map { "\($0.path)|\($0.fileName)" }) {
            guard let url = photo?.url else {
                fields = []
                histogram = nil
                return
            }
            let result = await Task.detached(priority: .utility) { () -> ([MetadataField], HistogramData?) in
                let details = MetadataReader.details(for: url)
                let histogram = ThumbnailCache.shared.thumbnail(for: url, maxPixel: 320).map { Histogram.compute($0.cgImage) }
                return (details, histogram)
            }.value
            withAnimation(Motion.smooth) {
                fields = result.0
                histogram = result.1
            }
        }
    }
}

struct PanelHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Palette.textSecondary)
            .padding(.top, 4)
    }
}
