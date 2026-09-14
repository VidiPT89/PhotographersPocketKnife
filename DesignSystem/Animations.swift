import SwiftUI

enum Motion {
    static let spring = Animation.spring(response: 0.6, dampingFraction: 0.7)
    static let snappy = Animation.spring(response: 0.35, dampingFraction: 0.82)
    static let smooth = Animation.easeInOut(duration: 0.35)
    static let pop = Animation.spring(response: 0.25, dampingFraction: 0.5)

    /// Sem escala: sliders, seletores e campos de texto (AppKit) inundam a consola quando são escalados a meio de uma animação.
    @MainActor static let moduleTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(y: 14)),
        removal: .opacity
    )
}

extension View {
    /// Brilho que atravessa o conteúdo (esqueletos de carregamento, barras ativas).
    func shimmer(active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }

    /// Entrada suave (fade + subida) com atraso opcional, para listas e grelhas.
    func appearAnimation(delay: Double = 0) -> some View {
        modifier(AppearModifier(delay: delay))
    }

    /// Levanta ligeiramente com sombra (laranja, por defeito) ao passar o rato.
    func hoverLift(scale: CGFloat = 1.02, glow: Bool = true) -> some View {
        modifier(HoverLiftModifier(scale: scale, glow: glow))
    }
}

private struct ShimmerModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay {
            if active, !reduceMotion {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width * 1.4)
                }
                .mask(content)
                .allowsHitTesting(false)
                .onAppear {
                    withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.2 }
                }
            }
        }
    }
}

private struct AppearModifier: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 10)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.snappy.delay(delay)) { visible = true }
            }
    }
}

private struct HoverLiftModifier: ViewModifier {
    let scale: CGFloat
    let glow: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? scale : 1)
            .shadow(
                color: hovering ? (glow ? Brand.orange.opacity(0.35) : .black.opacity(0.25)) : .clear,
                radius: hovering ? 14 : 0,
                y: hovering ? 6 : 0
            )
            .onHover { hover in withAnimation(Motion.snappy) { hovering = hover } }
    }
}
