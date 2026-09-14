import SwiftUI

struct PhotoGridView: View {
    @Environment(AppState.self) private var app
    let list: [Photo]

    private let spacing: CGFloat = 10

    var body: some View {
        let culling = app.culling
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: culling.thumbnailSize, maximum: culling.thumbnailSize + 60), spacing: spacing)], spacing: spacing) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, photo in
                            PhotoCell(
                                photo: photo,
                                size: culling.thumbnailSize,
                                isSelected: culling.selection.contains(photo.id),
                                isFocused: culling.focusedID == photo.id,
                                duplicateGroup: culling.showDuplicatesOnly ? culling.duplicateGroups[photo.id] : nil,
                                cull: culling.showCullBadges ? culling.cullBadge(for: photo.id) : nil
                            )
                            .id(photo.id)
                            .appearAnimation(delay: index < 40 ? Double(index) * 0.018 : 0)
                            .onTapGesture(count: 2) {
                                culling.focusedID = photo.id
                                culling.selection = [photo.id]
                                withAnimation(Motion.smooth) { culling.viewMode = .loupe }
                            }
                            .onTapGesture { culling.click(photo, in: list) }
                            .draggable(photo.url) {
                                ThumbnailView(url: photo.url, maxPixel: 320)
                                    .frame(width: 120, height: 90)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .shadow(radius: 8)
                            }
                            .contextMenu { PhotoContextMenu(photo: photo, list: list) }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: culling.focusedID) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.smooth) { proxy.scrollTo(id) }
                }
            }
            .onAppear { updateColumns(width: geo.size.width) }
            .onChange(of: geo.size.width) { _, width in updateColumns(width: width) }
            .onChange(of: culling.thumbnailSize) { _, _ in updateColumns(width: geo.size.width) }
        }
        .background(Palette.canvas)
        .folderDropTarget { app.culling.activeSheet = .importFolder($0) }
    }

    private func updateColumns(width: CGFloat) {
        app.culling.gridColumns = max(1, Int((width - 24 + spacing) / (app.culling.thumbnailSize + spacing)))
    }
}

struct PhotoCell: View {
    let photo: Photo
    let size: Double
    let isSelected: Bool
    let isFocused: Bool
    let duplicateGroup: Int?
    var cull: CullBadge?

    /// Contorno verde/vermelho que pulsa uma vez ao marcar pick/reject.
    @State private var flagPulse = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ThumbnailView(url: photo.url, maxPixel: size > 240 ? 640 : 320, recipeData: photo.recipeData)
                .frame(maxWidth: .infinity)
                .frame(height: size * 0.72)
                .overlay(alignment: .topTrailing) { FlagBadge(flag: photo.flag).padding(5) }
                .overlay(alignment: .topLeading) {
                    if let duplicateGroup {
                        Text("#\(duplicateGroup + 1)")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Brand.burntYellow, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let cull {
                        CullBadgeView(badge: cull)
                            .padding(5)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .animation(Motion.smooth, value: cull)
            HStack(spacing: 4) {
                StarRating(rating: photo.rating, size: 9)
                Spacer(minLength: 2)
                if let color = photo.colorLabel.color {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
            }
            Text(photo.fileName)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Brand.orange.opacity(0.16) : Palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isFocused ? Brand.orange : (isSelected ? Brand.orange.opacity(0.45) : Palette.separator), lineWidth: isFocused ? 2 : 1)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(photo.flag == .reject ? Brand.error : Brand.success, lineWidth: 3)
                .scaleEffect(1 + (1 - flagPulse) * 0.06)
                .opacity(flagPulse)
                .allowsHitTesting(false)
        }
        .onChange(of: photo.flagRaw) { _, newValue in
            guard newValue != 0 else { return }
            flagPulse = 1
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.7)) { flagPulse = 0 }
        }
        .shadow(color: Brand.orange.opacity(isFocused ? 0.4 : 0), radius: 10)
        .hoverLift(scale: 1.025)
        .opacity(photo.flag == .reject ? 0.45 : 1)
        .saturation(photo.flag == .reject ? 0.2 : 1)
        .animation(Motion.snappy, value: isSelected)
        .animation(Motion.snappy, value: isFocused)
        .animation(Motion.smooth, value: photo.flagRaw)
        .animation(Motion.smooth, value: photo.colorLabelRaw)
    }
}

struct PhotoContextMenu: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    let photo: Photo
    let list: [Photo]

    var body: some View {
        Button(app.t("context.showInFinder")) {
            NSWorkspace.shared.activateFileViewerSelecting([photo.url])
        }
        Button(app.t("context.edit")) {
            app.culling.focusedID = photo.id
            if !app.culling.selection.contains(photo.id) { app.culling.selection = [photo.id] }
            app.module = .editing
        }
        Button(app.t("context.addToUpload")) {
            app.module = .upload
            app.pendingUploadURLs = app.culling.targets(in: list).map(\.url)
        }
        Divider()
        Button(app.t("sidebar.removeFromCatalog"), role: .destructive) {
            let targets = app.culling.targets(in: list)
            app.culling.selection.subtract(targets.map(\.id))
            CatalogService.remove(targets, from: context)
        }
    }
}
