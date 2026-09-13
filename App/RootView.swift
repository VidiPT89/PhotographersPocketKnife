import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            if app.isSplashVisible {
                SplashScreenView {
                    withAnimation(.easeOut(duration: 0.5)) { app.isSplashVisible = false }
                }
                .transition(.opacity)
            } else {
                MainWindowView()
                    .transition(.opacity.combined(with: .scale(scale: 1.015)))
            }
        }
    }
}
