import SwiftUI
struct MobileFilters: View {
    @Environment(AppState.self) private var app
    let photos: [Photo]
    var body: some View {
        @Bindable var c = app.culling
        Form {
            Picker(app.m("Session", "Sessão"), selection: $c.session) {
                Text(app.m("All", "Todas")).tag(nil as String?)
                ForEach(Array(Set(photos.map(\.sessionName))).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            }
            Picker(app.m("Camera", "Câmara"), selection: $c.camera) {
                Text(app.m("All", "Todas")).tag(nil as String?)
                ForEach(Array(Set(photos.compactMap(\.camera))).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            }
            Picker(app.m("Lens", "Objetiva"), selection: $c.lens) {
                Text(app.m("All", "Todas")).tag(nil as String?)
                ForEach(Array(Set(photos.compactMap(\.lens))).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            }
            Picker(app.m("Minimum ISO", "ISO mínimo"), selection: $c.minISO) { ForEach(CullingModel.isoSteps, id: \.self) { Text("\($0)").tag($0) } }
            Picker(app.m("Focal length", "Distância focal"), selection: $c.focalLength) {
                Text(app.m("All", "Todas")).tag(nil as Double?)
                ForEach(Array(Set(photos.compactMap(\.focalLength))).sorted(), id: \.self) { Text("\(Int($0)) mm").tag(Optional($0)) }
            }
            Picker(app.m("Colour label", "Etiqueta de cor"), selection: $c.colorFilter) {
                Text(app.m("All", "Todas")).tag(nil as ColorLabel?)
                ForEach(ColorLabel.allCases) { Text(app.t($0.labelKey)).tag(Optional($0)) }
            }
            Picker(app.m("Delivery status", "Estado de entrega"), selection: $c.deliveryFilter) { ForEach(DeliveryFilter.allCases) { Text(app.t($0.labelKey)).tag($0) } }
            Toggle(app.m("Only duplicate groups", "Só grupos duplicados"), isOn: $c.showDuplicatesOnly)
            Toggle(app.m("Only photographs with issues", "Só fotografias com problemas"), isOn: $c.showIssuesOnly)
            Stepper(app.m("Thumbnail size: \(c.thumbnailStep + 1)", "Tamanho das miniaturas: \(c.thumbnailStep + 1)"), value: $c.thumbnailStep, in: 0...4)
            Button(app.m("Clear filters", "Limpar filtros")) { c.clearFilters() }
        }
    }
}
