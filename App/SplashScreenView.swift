import SwiftUI

struct SplashScreenView: View {
    @Environment(AppState.self) private var app
    let onFinish: () -> Void

    @State private var logoIn = false
    @State private var titleIn = false
    @State private var visibleLines = 0
    @State private var progress = 0.0
    @State private var shimmer = false

    private let duration = 2.2

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Brand.orange, Brand.burntYellow, Brand.black],
                startPoint: shimmer ? .topLeading : .top,
                endPoint: shimmer ? .bottomTrailing : .bottom
            )
            .opacity(0.9)
            .background(Brand.black)

            VStack(spacing: 18) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 88, weight: .thin))
                    .foregroundStyle(.white)
                    .scaleEffect(logoIn ? 1 : 0.6)
                    .opacity(logoIn ? 1 : 0)
                    .rotationEffect(.degrees(logoIn ? 0 : -45))

                Text("PhotographersPocketKnife")
                    .font(Typography.display)
                    .foregroundStyle(.white)
                    .opacity(titleIn ? 1 : 0)
                    .offset(y: titleIn ? 0 : 8)

                VStack(spacing: 6) {
                    creditLine(0) { Text(app.t("splash.developedBy") + " David Arsénio Martins") }
                    creditLine(1) { Link("ividi.dev", destination: URL(string: "https://ividi.dev")!) }
                    creditLine(2) { Link("github.com/VidiPT89", destination: URL(string: "https://github.com/VidiPT89")!) }
                }
                .font(Typography.body)
                .foregroundStyle(.white.opacity(0.85))
                .tint(.white)

                BrandProgressBar(value: progress)
                    .frame(width: 220)
                    .padding(.top, 12)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onFinish)
        .task { await animate() }
    }

    private func creditLine<Content: View>(_ index: Int, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .opacity(visibleLines > index ? 1 : 0)
            .offset(y: visibleLines > index ? 0 : 6)
    }

    private func animate() async {
        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { shimmer = true }
        withAnimation(Motion.spring) { logoIn = true }
        withAnimation(.linear(duration: duration)) { progress = 1 }
        try? await Task.sleep(for: .milliseconds(350))
        withAnimation(Motion.smooth) { titleIn = true }
        for line in 1...3 {
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(Motion.smooth) { visibleLines = line }
        }
        try? await Task.sleep(for: .milliseconds(Int(duration * 1000) - 1100))
        onFinish()
    }
}
