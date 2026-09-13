import SwiftUI

/// Botão primário: gradiente da marca, brilho no hover e "afundar" ao clicar.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
        }
        .buttonStyle(BrandButtonStyle())
    }
}

struct BrandButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        BrandButtonBody(configuration: configuration)
    }
}

private struct BrandButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(LinearGradient(
                    colors: hovering ? [Color(hex: 0xFF8A33), Brand.burntYellow] : [Brand.orange, Color(hex: 0xE8850A)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            }
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: Brand.orange.opacity(hovering ? 0.55 : 0.25), radius: hovering ? 12 : 5, y: hovering ? 4 : 2)
            .scaleEffect(configuration.isPressed ? 0.96 : (hovering ? 1.03 : 1))
            .opacity(isEnabled ? 1 : 0.5)
            .animation(Motion.snappy, value: configuration.isPressed)
            .onHover { hover in withAnimation(Motion.snappy) { hovering = hover } }
    }
}

/// Seletor em cápsula com o indicador a deslizar entre opções (módulos, idioma, tema).
struct PillPicker<Value: Hashable, Label: View>: View {
    @Binding var selection: Value
    let options: [Value]
    var compact = false
    @ViewBuilder let label: (Value, Bool) -> Label

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                PillOption(selected: option == selection, compact: compact, namespace: namespace) {
                    withAnimation(Motion.snappy) { selection = option }
                } label: {
                    label(option, option == selection)
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.panel))
        .overlay(Capsule().stroke(Palette.separator, lineWidth: 1))
    }
}

private struct PillOption<Label: View>: View {
    let selected: Bool
    let compact: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, compact ? 9 : 13)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Color.white : (hovering ? Palette.textPrimary : Palette.textSecondary))
                .background {
                    if selected {
                        Capsule()
                            .fill(Brand.diagonal)
                            .shadow(color: Brand.orange.opacity(0.45), radius: 6)
                            .matchedGeometryEffect(id: "pill", in: namespace)
                    } else if hovering {
                        Capsule().fill(Palette.separator.opacity(0.5))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover in withAnimation(Motion.snappy) { hovering = hover } }
    }
}

/// Barra de progresso com o gradiente da marca e brilho enquanto avança.
struct BrandProgressBar: View {
    let value: Double
    var track: Color = Palette.separator.opacity(0.6)

    var body: some View {
        let clamped = min(max(value, 0), 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(Brand.gradient)
                    .frame(width: geo.size.width * clamped)
                    .shimmer(active: clamped > 0 && clamped < 1)
                    .shadow(color: Brand.orange.opacity(0.5), radius: 4)
            }
        }
        .frame(height: 5)
        .animation(Motion.smooth, value: value)
    }
}

/// Estado vazio com ícone a flutuar e anéis a pulsar.
struct EmptyModuleView: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    Circle()
                        .stroke(Brand.orange.opacity(0.32 - Double(ring) * 0.09), lineWidth: 1)
                        .frame(width: 100 + CGFloat(ring) * 36, height: 100 + CGFloat(ring) * 36)
                        .scaleEffect(animate ? 1.07 : 0.95)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 2.2).repeatForever().delay(Double(ring) * 0.3), value: animate)
                }
                Circle()
                    .fill(RadialGradient(colors: [Brand.orange.opacity(0.28), .clear], center: .center, startRadius: 4, endRadius: 64))
                    .frame(width: 128, height: 128)
                Image(systemName: systemImage)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Brand.diagonal)
                    .offset(y: animate && !reduceMotion ? -5 : 3)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 2.6).repeatForever(), value: animate)
            }
            .frame(height: 180)
            .appearAnimation()

            Text(title)
                .font(Typography.title)
                .foregroundStyle(Palette.textPrimary)
                .appearAnimation(delay: 0.08)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .appearAnimation(delay: 0.16)
            }
            if let actionTitle, let action {
                PrimaryButton(title: actionTitle, systemImage: "plus", action: action)
                    .padding(.top, 6)
                    .appearAnimation(delay: 0.24)
            }
        }
        .padding(40)
        .onAppear { animate = true }
    }
}

/// Secção com título que abre e fecha com animação (painéis de ajustes).
struct CollapsibleSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Motion.snappy) { expanded.toggle() }
            } label: {
                HStack {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.textSecondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) { content() }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.background.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.separator.opacity(0.7), lineWidth: 1))
        .clipped()
    }
}

/// Ponto de estado com onda a pulsar quando está ativo.
struct PulsingDot: View {
    let color: Color
    let pulsing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.5))
                .frame(width: 7, height: 7)
                .scaleEffect(animate ? 2.6 : 1)
                .opacity(pulsing && !reduceMotion ? (animate ? 0 : 0.8) : 0)
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { animate = true }
        }
    }
}

/// Diafragma de 6 lâminas; `openness` anima de fechado (0) a aberto (1).
struct ApertureShape: Shape {
    var openness: Double

    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let inner = radius * (0.1 + 0.48 * openness)
        let twist = (1 - openness) * .pi / 5
        var path = Path()
        for blade in 0..<6 {
            let start = Double(blade) * .pi / 3
            let end = start + .pi / 3
            path.move(to: point(center, radius, start))
            path.addArc(center: center, radius: radius, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
            path.addLine(to: point(center, inner, end + twist))
            path.addLine(to: point(center, inner, start + twist))
            path.closeSubpath()
        }
        return path
    }

    private func point(_ center: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }
}

/// Mensagem curta que aparece por baixo da janela e desaparece sozinha.
struct ToastOverlay: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            if let toast = app.toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.icon)
                        .foregroundStyle(Brand.diagonal)
                        .symbolEffect(.bounce, value: toast.id)
                    Text(toast.message)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Brand.orange.opacity(0.45), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                .id(toast.id)
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(Motion.spring, value: app.toast)
        .allowsHitTesting(false)
    }
}
