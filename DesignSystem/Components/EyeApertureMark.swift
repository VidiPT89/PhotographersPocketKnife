import SwiftUI

/// Contorno de um olho (duas curvas que se encontram nos cantos). `openness` 0 = fechado, 1 = aberto.
struct EyeShape: Shape {
    var openness: Double

    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let lid = rect.width * 0.38 * max(openness, 0.02)
        let inset = rect.width * 0.275
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.midY),
                      control1: CGPoint(x: rect.minX + inset, y: rect.midY - lid),
                      control2: CGPoint(x: rect.maxX - inset, y: rect.midY - lid))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.midY),
                      control1: CGPoint(x: rect.maxX - inset, y: rect.midY + lid),
                      control2: CGPoint(x: rect.minX + inset, y: rect.midY + lid))
        path.closeSubpath()
        return path
    }
}

/// Símbolo da app: um olho cuja íris é o diafragma de uma objetiva (igual ao ícone).
struct EyeApertureMark: View {
    var eyeOpenness = 1.0
    var irisOpenness = 0.55

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let iris = width * 0.56
            ZStack {
                EyeShape(openness: eyeOpenness)
                    .fill(Color(hex: 0x15151C))
                ZStack {
                    Circle().fill(Brand.black).frame(width: iris, height: iris)
                    ApertureShape(openness: irisOpenness)
                        .fill(LinearGradient(colors: [Color(hex: 0xFBBF24), Color(hex: 0xF59E0B), Color(hex: 0xB45309)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(ApertureShape(openness: irisOpenness).stroke(Color.black.opacity(0.55), lineWidth: max(width * 0.008, 0.5)))
                        .frame(width: iris * 0.93, height: iris * 0.93)
                    Circle()
                        .stroke(LinearGradient(colors: [.white.opacity(0.85), Brand.orange.opacity(0.3)], startPoint: .top, endPoint: .bottom),
                                lineWidth: max(width * 0.018, 0.8))
                        .frame(width: iris * 0.95, height: iris * 0.95)
                    Circle()
                        .fill(.white.opacity(0.9))
                        .frame(width: width * 0.07, height: width * 0.07)
                        .offset(x: -width * 0.1, y: -width * 0.12)
                }
                .mask(EyeShape(openness: eyeOpenness))
                EyeShape(openness: eyeOpenness)
                    .stroke(LinearGradient(colors: [Color(hex: 0xFFF7E6), Color(hex: 0xFBBF24), Color(hex: 0xD97706)], startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: max(width * 0.04, 1.2), lineJoin: .round))
            }
            .frame(width: width, height: geo.size.height)
        }
        .aspectRatio(1.6, contentMode: .fit)
    }
}
