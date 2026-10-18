import SwiftUI

struct MobileStyle: View {
    @Environment(AppState.self) private var app
    let photos: [Photo]
    @State private var name = ""
    @State private var profiles = StyleProfileStore().all()
    @State private var busy = false
    @State private var folderPicker = false
    @State private var message: String?
    var body: some View {
        DisclosureGroup(app.m("Personal style", "Estilo pessoal")) {
            TextField(app.m("Style name", "Nome do estilo"), text: $name).textFieldStyle(.roundedBorder)
            Button(app.m("Learn from edited photos", "Aprender com fotografias editadas")) {
                let jobs = photos.compactMap { photo -> (URL, EditRecipe)? in
                    if let data = photo.recipeData, let recipe = try? JSONDecoder().decode(EditRecipe.self, from: data) { return (photo.url, recipe) }
                    if let recipe = LightroomPreset.sidecarRecipe(for: photo.url) { return (photo.url, recipe) }
                    return nil
                }
                learn { jobs.compactMap { ImageRenderer.shared.styleExample(url: $0.0, recipe: $0.1) } }
            }.disabled(name.isEmpty || busy)
            Button(app.m("Learn from delivered folder", "Aprender com pasta de fotografias entregues")) { folderPicker = true }.disabled(name.isEmpty || busy)
            ForEach(profiles) { profile in
                HStack {
                    Button(profile.name) { apply(profile) }.disabled(busy)
                    Spacer()
                    Button { UserDefaults.standard.set(profile.id.uuidString, forKey: "style.default"); app.showToast(app.m("Default style updated", "Estilo predefinido atualizado")) } label: { Image(systemName: "star") }
                    Button(role: .destructive) { StyleProfileStore().delete(profile.id); profiles = StyleProfileStore().all() } label: { Image(systemName: "trash") }
                }.padding(.vertical, 5)
            }
            if busy { ProgressView() }
            if let message { Text(message).font(.caption) }
        }
        .fileImporter(isPresented: $folderPicker, allowedContentTypes: [.folder]) { result in
            do {
                let folder = try result.get()
                let access = folder.startAccessingSecurityScopedResource()
                let jobs = photos.map { ($0.url, $0.fileName) }
                learn {
                    defer { if access { folder.stopAccessingSecurityScopedResource() } }
                    let files = PhotoImporter.imageFiles(in: folder)
                    return jobs.compactMap { source, name in
                        guard let final = files.first(where: { TasteLearner.isMatch(original: name, deliveredBase: $0.deletingPathExtension().lastPathComponent) }) else { return nil }
                        return ImageRenderer.shared.fittedStyleExample(original: source, final: final)
                    }
                }
            } catch { message = error.localizedDescription }
        }
    }
    private func learn(_ make: @escaping @Sendable () -> [StyleExample]) {
        busy = true
        let name = name
        Task {
            let examples = await Task.detached { make() }.value
            if examples.count >= PersonalStyle.minimumExamples {
                StyleProfileStore().save(StyleProfile(name: name, examples: examples)); profiles = StyleProfileStore().all(); self.name = ""
                message = app.m("Style learned from \(examples.count) photographs", "Estilo aprendido com \(examples.count) fotografias")
            } else { message = app.m("At least three edited photographs are needed.", "São necessárias pelo menos três fotografias editadas.") }
            busy = false
        }
    }
    private func apply(_ profile: StyleProfile) {
        let selected = app.culling.targets(in: photos)
        let targets = selected.isEmpty ? photos.filter { $0.id == app.editing.photo?.id } : selected
        let jobs = targets.map { ($0.id, $0.url, $0.recipeData.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) } ?? EditRecipe()) }
        busy = true
        Task {
            let results = await Task.detached { jobs.compactMap { id, url, recipe in ImageRenderer.shared.styled(url: url, profile: profile, current: recipe).map { (id, $0) } } }.value
            for (id, recipe) in results {
                if let photo = targets.first(where: { $0.id == id }) { app.editing.applySettings(recipe, labelKey: "history.style", to: [photo]) }
            }
            busy = false
        }
    }
}
