import SwiftUI
import SwiftData

/// Perfis de gosto na Seleção inteligente: escolher um e criar novos a partir das escolhas do fotógrafo.
struct TasteProfileSection: View {
    @Environment(AppState.self) private var app
    @Query(sort: \Photo.importedAt) private var catalog: [Photo]
    @Binding var selectedID: String

    @State private var profiles: [TasteProfile] = []
    @State private var newName = ""
    @State private var message: String?
    private let store = TasteProfileStore()

    var body: some View {
        let decided = CullingModel.decisionExamples(catalog)
        Section(app.t("taste.title")) {
            Picker(app.t("taste.use"), selection: $selectedID) {
                Text(app.t("taste.none")).tag("")
                ForEach(profiles) { profile in
                    Text("\(profile.name) · \(profile.keepers) / \(profile.rejects)").tag(profile.id.uuidString)
                }
            }
            Text(app.t(selectedID.isEmpty ? "taste.noneHint" : "taste.useHint"))
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
            DisclosureGroup(app.t("taste.create")) {
                TextField(app.t("taste.name"), text: $newName)
                Text(String(format: app.t("taste.fromDecisionsHint"), decided.keepers.count, decided.rejects.count))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                HStack {
                    Button(app.t("taste.fromDecisions")) { learn(decided) }
                        .disabled(!canLearn || decided.keepers.count < TasteLearner.minimumPerClass || decided.rejects.count < TasteLearner.minimumPerClass)
                    Button(app.t("taste.fromFolder")) { learnFromFolder() }
                        .disabled(!canLearn)
                }
                ForEach(profiles) { profile in
                    HStack {
                        Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(Brand.orange)
                        Text(profile.name)
                        Spacer()
                        Button(role: .destructive) {
                            store.delete(profile.id)
                            if selectedID == profile.id.uuidString { selectedID = "" }
                            profiles = store.all()
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                if let message {
                    Text(message).font(Typography.caption).foregroundStyle(Brand.orange)
                }
            }
        }
        .onAppear { profiles = store.all() }
    }

    private var canLearn: Bool {
        !app.culling.isAnalyzing && !newName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func learn(_ examples: (keepers: [Photo], rejects: [Photo])) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let culling = app.culling
        Task {
            if let profile = await culling.learnTaste(named: name, keepers: examples.keepers, rejects: examples.rejects) {
                store.save(profile)
                profiles = store.all()
                selectedID = profile.id.uuidString
                newName = ""
                message = String(format: app.t("taste.learned"), profile.keepers, profile.rejects)
            } else {
                message = String(format: app.t("taste.notEnough"), TasteLearner.minimumPerClass)
            }
        }
    }

    private func learnFromFolder() {
        guard let folder = FilePanels.chooseFolder(prompt: app.t("common.choose")) else { return }
        learn(CullingModel.folderExamples(catalog, delivered: PhotoImporter.imageFiles(in: folder)))
    }
}
