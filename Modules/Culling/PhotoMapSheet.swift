import SwiftUI
import SwiftData
import MapKit

/// Mapa com as fotos que têm GPS; clicar numa abre-a na lupa.
struct PhotoMapSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let photos: [Photo]

    @State private var isReading = true
    @State private var position: MapCameraPosition = .automatic

    private var located: [Photo] { photos.filter { $0.latitude != nil && $0.longitude != nil } }

    var body: some View {
        let pins = located
        VStack(spacing: 0) {
            ZStack {
                Map(position: $position) {
                    ForEach(pins) { photo in
                        Annotation(photo.fileName, coordinate: CLLocationCoordinate2D(latitude: photo.latitude ?? 0, longitude: photo.longitude ?? 0)) {
                            Button { open(photo) } label: {
                                // Com muitas fotos, pontos em vez de miniaturas (o mapa continua fluido).
                                if pins.count > 150 {
                                    Circle().fill(Brand.orange).frame(width: 10, height: 10)
                                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                } else {
                                    ThumbnailView(url: photo.url, maxPixel: 160)
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.orange, lineWidth: 2))
                                        .shadow(color: .black.opacity(0.4), radius: 3)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(photo.fileName)
                        }
                    }
                }
                .mapControls {
                    MapZoomStepper()
                    MapCompass()
                }
                if isReading {
                    ProgressView().controlSize(.large)
                } else if pins.isEmpty {
                    EmptyModuleView(systemImage: "location.slash", title: app.t("map.empty"), subtitle: app.t("map.emptyHint"))
                        .frame(width: 360, height: 220)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            HStack {
                Text(String(format: app.t("map.count"), pins.count, photos.count))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button(app.t("cull.done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 860, height: 620)
        .task { await readMissingCoordinates() }
    }

    /// Fotos importadas antes de o catálogo guardar o GPS: lê-se do ficheiro e fica guardado.
    private func readMissingCoordinates() async {
        let pending = photos.filter { $0.latitude == nil }.map { (id: $0.id, url: $0.url) }
        let found = await Task.detached(priority: .userInitiated) { () -> [UUID: [Double]] in
            var result: [UUID: [Double]] = [:]
            for item in pending {
                if let coordinate = MetadataReader.coordinate(from: MetadataReader.properties(for: item.url)) {
                    result[item.id] = [coordinate.latitude, coordinate.longitude]
                }
            }
            return result
        }.value
        for photo in photos {
            guard let coordinate = found[photo.id] else { continue }
            photo.latitude = coordinate[0]
            photo.longitude = coordinate[1]
        }
        if !found.isEmpty { try? photos.first?.modelContext?.save() }
        isReading = false
    }

    private func open(_ photo: Photo) {
        app.culling.selection = [photo.id]
        app.culling.focusedID = photo.id
        app.culling.viewMode = .loupe
        dismiss()
    }
}
