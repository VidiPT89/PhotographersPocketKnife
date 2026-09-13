import SwiftUI

enum Motion {
    static let spring = Animation.spring(response: 0.6, dampingFraction: 0.7)
    static let smooth = Animation.easeInOut(duration: 0.35)
    static let pop = Animation.spring(response: 0.25, dampingFraction: 0.5)

    @MainActor static let moduleTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .move(edge: .trailing)),
        removal: .opacity
    )
}
