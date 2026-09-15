import SwiftUI

struct SplashScreenView: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onFinish: () -> Void

    /// 0 escondido · 1 diafragma · 2 nome · 3 slogan · 4 criador · 5 links
    @State private var stage = 0
    @State private var apertureOpen = false
    @State private var progress = 0.0
    @State private var sweep: CGFloat = -1
    @State private var exiting = false

    var body: some View {
        ZStack {
            SplashBackground()

            VStack(spacing: 0) {
                aperture
                    .scaleEffect(stage >= 1 ? 1 : 0.4)
                    .opacity(stage >= 1 ? 1 : 0)

                title
                    .padding(.top, 30)
                    .opacity(stage >= 2 ? 1 : 0)
                    .offset(y: stage >= 2 ? 0 : 14)
                    .blur(radius: stage >= 2 ? 0 : 6)

                Text(app.t("splash.tagline"))
                    .font(.system(size: 13, weight: .medium))
                    .tracking(3)
                    .foregroundStyle(Brand.amber.opacity(0.9))
                    .padding(.top, 10)
                    .opacity(stage >= 3 ? 1 : 0)
                    .offset(y: stage >= 3 ? 0 : 8)

                VStack(spacing: 14) {
                    Text("\(app.t("splash.developedBy")) \(Text("David Arsénio Martins").fontWeight(.semibold).foregroundStyle(.white))")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .opacity(stage >= 4 ? 1 : 0)
                        .offset(y: stage >= 4 ? 0 : 8)

                    HStack(spacing: 10) {
                        CreditLink(icon: "globe", title: "ividi.dev", url: URL(string: "https://ividi.dev/")!)
                        CreditLink(icon: "chevron.left.forwardslash.chevron.right", title: "github.com/VidiPT89", url: URL(string: "https://github.com/VidiPT89/")!)
                    }
                    .opacity(stage >= 5 ? 1 : 0)
                    .offset(y: stage >= 5 ? 0 : 8)
                }
                .padding(.top, 44)

                BrandProgressBar(value: progress, track: .white.opacity(0.1))
                    .frame(width: 240)
                    .padding(.top, 40)
                    .opacity(stage >= 1 ? 1 : 0)
            }
        }
        .scaleEffect(exiting && !reduceMotion ? 1.06 : 1)
        .blur(radius: exiting && !reduceMotion ? 14 : 0)
        .opacity(exiting ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: finish)
        .task { await run() }
    }

    private var aperture: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Brand.orange.opacity(0.55), .clear], center: .center, startRadius: 10, endRadius: 150))
                .frame(width: 300, height: 300)
                .blur(radius: 18)
                .scaleEffect(apertureOpen ? 1 : 0.6)

            // O olho abre e, logo a seguir, o diafragma da íris.
            EyeApertureMark(eyeOpenness: apertureOpen ? 1 : 0.04, irisOpenness: apertureOpen ? 0.55 : 0)
                .frame(width: 200)
                .shadow(color: Brand.orange.opacity(0.6), radius: 26)
        }
        .frame(height: 170)
    }

    private var titleText: some View {
        Text("Photographer's Pocket Knife")
            .font(Typography.hero)
            .tracking(-0.5)
    }

    private var title: some View {
        titleText
            .foregroundStyle(LinearGradient(colors: [.white, Color(hex: 0xFFE2C4)], startPoint: .top, endPoint: .bottom))
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.95), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 110)
                        .offset(x: sweep * (geo.size.width + 110) / 2 + geo.size.width / 2 - 55)
                }
                .mask(titleText)
                .allowsHitTesting(false)
            }
            .shadow(color: Brand.orange.opacity(0.35), radius: 18)
    }

    private func run() async {
        if reduceMotion {
            stage = 5
            apertureOpen = true
            progress = 1
            try? await Task.sleep(for: .seconds(1.6))
            finish()
            return
        }
        withAnimation(Motion.spring) { stage = 1 }
        withAnimation(.easeInOut(duration: 2.6)) { progress = 1 }
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(.spring(response: 1.1, dampingFraction: 0.72)) { apertureOpen = true }
        for next in 2...5 {
            try? await Task.sleep(for: .milliseconds(next == 2 ? 420 : 220))
            withAnimation(Motion.snappy) { stage = next }
        }
        withAnimation(.easeInOut(duration: 1.0)) { sweep = 1 }
        try? await Task.sleep(for: .milliseconds(1100))
        finish()
    }

    private func finish() {
        guard !exiting else { return }
        withAnimation(.easeIn(duration: 0.45)) { exiting = true }
        Task {
            try? await Task.sleep(for: .milliseconds(420))
            onFinish()
        }
    }
}

private struct CreditLink: View {
    let icon: String
    let title: String
    let url: URL
    @State private var hovering = false

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(hovering ? Color.white : Color.white.opacity(0.8))
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(hovering ? 0.14 : 0.06)))
            .overlay(Capsule().stroke(hovering ? Brand.orange : .white.opacity(0.16), lineWidth: 1))
            .shadow(color: Brand.orange.opacity(hovering ? 0.5 : 0), radius: 8)
            .scaleEffect(hovering ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover in withAnimation(Motion.snappy) { hovering = hover } }
    }
}

/// Fundo escuro com brilhos laranja a respirar e bokeh a subir devagar.
private struct SplashBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(Gradient(colors: [Color(hex: 0x1C1008), Brand.black, Color(hex: 0x060606)]),
                                          startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height))
                )

                let glows: [(color: Color, x: Double, y: Double, size: Double)] = [
                    (Brand.orange, 0.22, 0.78, 0.55),
                    (Brand.burntYellow, 0.82, 0.25, 0.45),
                    (Brand.orange, 0.62, 0.95, 0.4),
                ]
                for (index, glow) in glows.enumerated() {
                    let x = size.width * (glow.x + 0.05 * sin(t * 0.3 + Double(index)))
                    let y = size.height * (glow.y + 0.05 * cos(t * 0.25 + Double(index) * 2))
                    let radius = max(size.width, size.height) * glow.size
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                        with: .radialGradient(Gradient(colors: [glow.color.opacity(0.32), .clear]),
                                              center: CGPoint(x: x, y: y), startRadius: 0, endRadius: radius)
                    )
                }

                for index in 0..<24 {
                    let seed = Double(index) * 12.9898
                    let baseX = abs((sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1))
                    let baseY = abs((sin(seed * 1.7) * 24634.6345).truncatingRemainder(dividingBy: 1))
                    var y = (baseY - t * (0.015 + 0.03 * baseX)).truncatingRemainder(dividingBy: 1.2)
                    if y < 0 { y += 1.2 }
                    y -= 0.1
                    let x = baseX + 0.02 * sin(t * 0.5 + seed)
                    let radius = 5 + 28 * baseY
                    let color = index % 3 == 0 ? Brand.amber : Brand.orange
                    context.fill(
                        Path(ellipseIn: CGRect(x: x * size.width - radius, y: y * size.height - radius, width: radius * 2, height: radius * 2)),
                        with: .color(color.opacity(0.05 + 0.09 * baseX))
                    )
                }
            }
        }
        .overlay(RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 200, endRadius: 900))
        .ignoresSafeArea()
    }
}
