import SwiftUI

struct LoupeView: View {
    @Environment(AppState.self) private var app
    let list: [Photo]

    var body: some View {
        if let photo = app.culling.focused(in: list) ?? list.first {
            VStack(spacing: 0) {
                ThumbnailView(url: photo.url, maxPixel: 2400, recipeData: photo.recipeData, fit: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
                    .id(photo.id)
                    .transition(.opacity)
                PhotoCaptionBar(photo: photo)
                FilmStrip(list: list)
            }
            .animation(Motion.smooth, value: photo.id)
            .onAppear { if app.culling.focusedID == nil { app.culling.focusedID = photo.id } }
        } else {
            EmptyModuleView(systemImage: "rectangle", title: app.t("filter.noResults"), subtitle: "")
        }
    }
}

struct CompareView: View {
    @Environment(AppState.self) private var app
    let list: [Photo]

    var body: some View {
        let photos = app.culling.comparePhotos(in: list)
        let columns = photos.count <= 2 ? max(photos.count, 1) : 2
        GeometryReader { geo in
            let rows = CGFloat((photos.count + columns - 1) / columns)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(photos) { photo in
                    let focused = app.culling.focusedID == photo.id
                    VStack(spacing: 0) {
                        ThumbnailView(url: photo.url, maxPixel: 1600, recipeData: photo.recipeData, fit: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(8)
                        PhotoCaptionBar(photo: photo)
                    }
                    .frame(height: max(120, (geo.size.height - 8 * (rows - 1) - 24) / max(rows, 1)))
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Brand.orange : .clear, lineWidth: 2))
                    .onTapGesture { app.culling.focusedID = photo.id }
                }
            }
            .padding(12)
        }
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
            Text([photo.camera, photo.lens].compactMap { $0 }.joined(separator: " · "))
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
                            .opacity(photo.flag == .reject ? 0.45 : 1)
                            .id(photo.id)
                            .onTapGesture { app.culling.click(photo, in: list) }
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
