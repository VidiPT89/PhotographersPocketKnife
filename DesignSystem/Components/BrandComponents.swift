import SwiftUI

/// Botão primário com glow laranja no hover.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                if let systemImage { Image(systemName: systemImage) }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Brand.gradient, in: Capsule())
            .shadow(color: Brand.orange.opacity(hovering ? 0.6 : 0), radius: 10)
            .scaleEffect(hovering ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover in withAnimation(Motion.smooth) { hovering = hover } }
    }
}

/// Barra de progresso com o gradiente da marca.
struct BrandProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(Brand.gradient)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

/// Estado vazio usado pelos módulos ainda por implementar.
struct EmptyModuleView: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Brand.gradient)
            Text(title).font(Typography.title).foregroundStyle(Palette.textPrimary)
            Text(subtitle).font(Typography.body).foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                PrimaryButton(title: actionTitle, systemImage: "plus", action: action).padding(.top, 6)
            }
        }
        .padding(40)
    }
}
