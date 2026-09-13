import SwiftUI

struct CullingView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        EmptyModuleView(
            systemImage: "photo.stack",
            title: app.t("culling.empty.title"),
            subtitle: app.t("culling.empty.subtitle"),
            actionTitle: app.t("culling.import"),
            action: {}
        )
    }
}
