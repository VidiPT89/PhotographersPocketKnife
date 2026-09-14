import SwiftUI
import SwiftData

struct PresetsPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \EditPreset.name) private var presets: [EditPreset]
    let list: [Photo]
    @State private var newName = ""

    var body: some View {
        let editing = app.editing
        HStack {
            TextField(app.t("presets.name"), text: $newName)
                .textFieldStyle(.roundedBorder)
            Button(app.t("presets.save")) {
                guard let data = try? JSONEncoder().encode(editing.recipe) else { return }
                context.insert(EditPreset(name: newName.trimmingCharacters(in: .whitespaces), recipeData: data))
                try? context.save()
                newName = ""
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        HStack(alignment: .top) {
            Text(app.t("presets.hint"))
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Button(action: importPresets) {
                Label(app.t("presets.import"), systemImage: "square.and.arrow.down")
            }
        }

        if presets.isEmpty {
            Text(app.t("presets.empty")).foregroundStyle(Palette.textSecondary)
        }
        ForEach(presets) { preset in
            HStack {
                Text(preset.name)
                Spacer()
                Button(app.t("presets.apply")) {
                    guard let recipe = try? JSONDecoder().decode(EditRecipe.self, from: preset.recipeData) else { return }
                    editing.hoverPreview = nil
                    let targets = app.culling.targets(in: list)
                    editing.applySettings(recipe, labelKey: "history.preset", to: targets.isEmpty ? list.filter { $0.id == editing.photo?.id } : targets)
                    editing.flashPreset()
                }
                Button { export(preset) } label: { Image(systemName: "square.and.arrow.up") }
                    .help(app.t("presets.export"))
                Button(role: .destructive) {
                    context.delete(preset)
                    try? context.save()
                } label: { Image(systemName: "trash") }
            }
            .padding(8)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 6))
            .hoverLift(scale: 1.01, glow: true)
            // Pré-visualização do preset na foto enquanto o rato está por cima.
            .onHover { hovering in
                if hovering, let recipe = try? JSONDecoder().decode(EditRecipe.self, from: preset.recipeData) {
                    editing.hoverPreview = editing.recipe.applyingSettings(from: recipe)
                } else {
                    editing.hoverPreview = nil
                }
            }
        }
        StylePanel(list: list)
    }

    private func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [PresetFile.contentType]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var imported = 0
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url),
                  let file = try? PresetFile.decode(data),
                  let recipeData = try? JSONEncoder().encode(file.recipe) else { continue }
            context.insert(EditPreset(name: file.name, recipeData: recipeData))
            imported += 1
        }
        try? context.save()
        if imported > 0 {
            app.showToast(app.t("toast.presetsImported"), icon: "square.and.arrow.down.fill")
        } else {
            app.showToast(app.t("toast.presetsInvalid"), icon: "exclamationmark.triangle.fill")
        }
    }

    private func export(_ preset: EditPreset) {
        guard let recipe = try? JSONDecoder().decode(EditRecipe.self, from: preset.recipeData) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [PresetFile.contentType]
        panel.nameFieldStringValue = "\(RenameTemplate.sanitize(preset.name)).\(PresetFile.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PresetFile(name: preset.name, recipe: recipe).encoded().write(to: url, options: .atomic)
            app.showToast(app.t("toast.presetExported"), icon: "square.and.arrow.up.fill")
        } catch {
            app.showToast(error.localizedDescription, icon: "exclamationmark.triangle.fill")
        }
    }
}
