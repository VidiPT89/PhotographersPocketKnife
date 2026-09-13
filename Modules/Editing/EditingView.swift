import SwiftUI

struct EditingView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        EmptyModuleView(
            systemImage: "slider.horizontal.3",
            title: app.t("editing.empty.title"),
            subtitle: app.t("editing.empty.subtitle")
        )
    }
}
