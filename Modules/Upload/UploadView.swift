import SwiftUI

struct UploadView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        EmptyModuleView(
            systemImage: "arrow.up.to.line.circle",
            title: app.t("upload.empty.title"),
            subtitle: app.t("upload.empty.subtitle")
        )
    }
}
