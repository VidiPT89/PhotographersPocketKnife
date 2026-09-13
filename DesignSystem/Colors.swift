import SwiftUI
import AppKit

/// Cores fixas da marca (ividi.dev), iguais em qualquer tema.
enum Brand {
    static let orange = Color(hex: 0xFF7A1A)
    static let burntYellow = Color(hex: 0xD98A00)
    static let black = Color(hex: 0x0E0E0F)
    static let success = Color(hex: 0x3FBE6B)
    static let error = Color(hex: 0xE5484D)

    static let gradient = LinearGradient(colors: [orange, burntYellow], startPoint: .leading, endPoint: .trailing)
}

/// Cores semânticas que se adaptam a Dark/Light.
enum Palette {
    static let background = Color(light: 0xF5F3F0, dark: 0x0E0E0F)
    static let panel = Color(light: 0xFFFFFF, dark: 0x1A1A1C)
    static let separator = Color(light: 0xD8D6D2, dark: 0x2A2A2C)
    static let textPrimary = Color(light: 0x1A1A1C, dark: 0xF5F3F0)
    static let textSecondary = Color(hex: 0x8A8A8E)
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
