import SwiftUI
import AppKit

/// Cores da marca, retiradas do CSS de ividi.dev. Iguais em qualquer tema.
enum Brand {
    static let orange = Color(hex: 0xD97706)
    static let orangeBright = Color(hex: 0xF59E0B)
    static let amber = Color(hex: 0xFBBF24)
    static let ember = Color(hex: 0xB45309)
    /// Nome antigo mantido para o acento secundário (hover, badges, estados de espera).
    static let burntYellow = orangeBright
    static let black = Color(hex: 0x0A0A0F)
    static let success = Color(hex: 0x4ADE80)
    static let error = Color(hex: 0xEF4444)

    static let gradient = LinearGradient(colors: [orange, orangeBright], startPoint: .leading, endPoint: .trailing)
    static let diagonal = LinearGradient(colors: [orange, amber], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Cores semânticas que se adaptam a Dark/Light. O laranja e o âmbar mantêm-se nos dois modos.
enum Palette {
    static let background = Color(light: 0xFAFAF7, dark: 0x0A0A0F)
    static let panel = Color(light: 0xFFFFFF, dark: 0x1A1A22)
    /// Fundo neutro atrás das fotos: nenhum tom da marca, para não falsear a leitura de cor.
    static let canvas = Color(light: 0xE8E8E8, dark: 0x1A1A1A)
    static let separator = Color(light: 0xE2E0DA, dark: 0x33333F)
    static let textPrimary = Color(light: 0x14141A, dark: 0xF5F5F0)
    static let textSecondary = Color(light: 0x71717A, dark: 0xA1A1AA)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }
}
