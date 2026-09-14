import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Estilo pessoal: aprende com as edições feitas aqui, com as revelações do Lightroom (.xmp)
/// e com pastas de fotos já entregues. Também importa presets do Lightroom.
struct StylePanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    let list: [Photo]

    @AppStorage("style.default") private var defaultStyleID = ""
    @State private var profiles: [StyleProfile] = []
    @State private var newName = ""
    @State private var isLearning = false
    @State private var applyingID: UUID?
    private let store = StyleProfileStore()

    var body: some View {
        let edited = list.filter { $0.recipeData != nil }
        PanelHeader(title: app.t("style.title"))
            .onAppear { profiles = store.all() }
        Text(String(format: app.t("style.hint"), edited.count))
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
        TextField(app.t("style.name"), text: $newName)
            .textFieldStyle(.roundedBorder)
        HStack {
            Button { learnFromEdits() } label: {
                if isLearning { ProgressView().controlSize(.mini) } else { Text(app.t("style.learn")) }
            }
            Button(app.t("style.fromFinals")) { learnFromDelivered() }
        }
        .disabled(isLearning || newName.trimmingCharacters(in: .whitespaces).isEmpty)

        ForEach(profiles) { profile in
            let isDefault = defaultStyleID == profile.id.uuidString
            HStack(spacing: 8) {
                Button { defaultStyleID = isDefault ? "" : profile.id.uuidString } label: {
                    Image(systemName: isDefault ? "star.fill" : "star").foregroundStyle(Brand.amber)
                }
                .buttonStyle(.borderless)
                .help(app.t("style.default"))
                VStack(alignment: .leading, spacing: 0) {
                    Text(profile.name)
                    Text(String(format: app.t("style.examples"), profile.examples.count))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button { apply(profile) } label: {
                    if applyingID == profile.id { ProgressView().controlSize(.mini) } else { Text(app.t("presets.apply")) }
                }
                .disabled(applyingID != nil)
                Button(role: .destructive) {
                    store.delete(profile.id)
                    if isDefault { defaultStyleID = "" }
                    profiles = store.all()
                } label: { Image(systemName: "trash") }
            }
            .padding(8)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 6))
            .appearAnimation()
        }
        Button(action: importLightroom) {
            Label(app.t("style.importLightroom"), systemImage: "square.and.arrow.down.on.square")
        }
    }

    /// Edições feitas nesta app e, nas fotos sem edição, a revelação do Lightroom no `.xmp` ao lado.
    private func learnFromEdits() {
        let jobs = Array(list.prefix(500)).map { photo in
            (url: photo.url, recipe: photo.recipeData.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) })
        }
        learn {
            jobs.compactMap { job in
                (job.recipe ?? LightroomPreset.sidecarRecipe(for: job.url)).flatMap { ImageRenderer.shared.styleExample(url: job.url, recipe: $0) }
            }
        }
    }

    /// Originais do catálogo emparelhados com as versões finais entregues (editadas noutro programa).
    private func learnFromDelivered() {
        guard let folder = FilePanels.chooseFolder(prompt: app.t("common.choose")) else { return }
        let delivered = PhotoImporter.imageFiles(in: folder)
        let pairs = list.compactMap { photo -> (URL, URL)? in
            delivered.first { TasteLearner.isMatch(original: photo.fileName, deliveredBase: $0.deletingPathExtension().lastPathComponent) }
                .map { (photo.url, $0) }
        }
        guard !pairs.isEmpty else {
            app.showToast(app.t("style.noPairs"), icon: "exclamationmark.triangle.fill")
            return
        }
        let limited = Array(pairs.prefix(300))
        learn {
            limited.compactMap { ImageRenderer.shared.fittedStyleExample(original: $0.0, final: $0.1) }
        }
    }

    private func learn(_ makeExamples: @escaping @Sendable () -> [StyleExample]) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let store = store
        isLearning = true
        Task {
            let examples = await Task.detached(priority: .userInitiated) { makeExamples() }.value
            isLearning = false
            guard examples.count >= PersonalStyle.minimumExamples else {
                app.showToast(app.t("style.notEnough"), icon: "exclamationmark.triangle.fill")
                return
            }
            store.save(StyleProfile(name: name, examples: examples))
            newName = ""
            profiles = store.all()
            app.showToast(String(format: app.t("toast.styleLearned"), examples.count), icon: "sparkles")
        }
    }

    private func apply(_ profile: StyleProfile) {
        let editing = app.editing
        let targets = app.culling.targets(in: list)
        let photos = targets.isEmpty ? list.filter { $0.id == editing.photo?.id } : targets
        let jobs = photos.map { photo in
            (id: photo.id, url: photo.url, recipe: photo.recipeData.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) } ?? EditRecipe())
        }
        applyingID = profile.id
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                jobs.compactMap { job in ImageRenderer.shared.styled(url: job.url, profile: profile, current: job.recipe).map { (job.id, $0) } }
            }.value
            for (id, recipe) in results {
                if let photo = photos.first(where: { $0.id == id }) {
                    editing.applySettings(recipe, labelKey: "history.style", to: [photo])
                }
            }
            applyingID = nil
            editing.flashPreset()
            app.showToast(String(format: app.t("toast.styleApplied"), results.count), icon: "sparkles")
        }
    }

    private func importLightroom() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xmp") ?? .xml]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var imported = 0
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url),
                  let preset = LightroomPreset.parse(data),
                  let recipeData = try? JSONEncoder().encode(preset.recipe) else { continue }
            context.insert(EditPreset(name: preset.name ?? url.deletingPathExtension().lastPathComponent, recipeData: recipeData))
            imported += 1
        }
        try? context.save()
        if imported > 0 {
            app.showToast(String(format: app.t("toast.lightroomImported"), imported), icon: "square.and.arrow.down.fill")
        } else {
            app.showToast(app.t("toast.presetsInvalid"), icon: "exclamationmark.triangle.fill")
        }
    }
}
