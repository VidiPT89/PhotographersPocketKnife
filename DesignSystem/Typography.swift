import SwiftUI

enum Typography {
    static let hero = Font.system(size: 44, weight: .bold, design: .rounded)
    static let title = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
}

extension View {
    /// Etiqueta com texto e ícone, ou só ícone quando a barra não tem espaço.
    @ViewBuilder
    func toolbarLabelStyle(compact: Bool) -> some View {
        if compact {
            labelStyle(.iconOnly)
        } else {
            labelStyle(.titleAndIcon)
        }
    }
}
