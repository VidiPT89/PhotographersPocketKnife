import SwiftUI

/// Shared normalized viewport keeps comparison panes aligned even after a resize.
struct ZoomPosition: Equatable {
    var scale: CGFloat = 1
    var x: CGFloat = 0.5
    var y: CGFloat = 0.5

    func offset(in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(x * size.width * scale - size.width / 2, 0), size.width * (scale - 1)),
                y: min(max(y * size.height * scale - size.height / 2, 0), size.height * (scale - 1)))
    }

    /// Preview resolution multiplier for this zoom; 3× needs more than 5 GB so RAW previews fit in memory.
    func previewDetail(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Double {
        let detail: Double = scale > 3 ? 3 : scale > 1.5 ? 2 : 1
        return physicalMemory > 5 << 30 ? detail : min(detail, 2)
    }
}

// In an extension so the struct keeps its memberwise and empty initialisers.
extension ZoomPosition {
    static let maxScale: CGFloat = 6

    /// The position whose offset is `offset`, at `scale`; anything at or below 1× fits the photograph.
    init(scale: CGFloat, offset: CGPoint, in size: CGSize) {
        let scale = min(max(scale, 1), Self.maxScale)
        guard scale > 1.001, size.width > 0, size.height > 0 else { self.init(); return }
        let limit = 1 / (2 * scale)
        self.init(scale: scale,
                  x: min(max((offset.x + size.width / 2) / (size.width * scale), limit), 1 - limit),
                  y: min(max((offset.y + size.height / 2) / (size.height * scale), limit), 1 - limit))
    }

    /// Zooms to `scale` keeping the photograph point under `anchor` (a point in the viewport) where it is.
    func zoomed(to scale: CGFloat, around anchor: CGPoint, in size: CGSize) -> ZoomPosition {
        let current = offset(in: size)
        let target = min(max(scale, 1), Self.maxScale)
        let point = CGPoint(x: (current.x + anchor.x) / self.scale, y: (current.y + anchor.y) / self.scale)
        return ZoomPosition(scale: target, offset: CGPoint(x: point.x * target - anchor.x, y: point.y * target - anchor.y), in: size)
    }

    /// Zooms around the viewport centre; a factor of 0 fits the photograph.
    func stepped(_ factor: CGFloat) -> ZoomPosition {
        let target = min(max(scale * factor, 1), Self.maxScale)
        guard factor > 0, target > 1.001 else { return ZoomPosition() }
        let limit = 1 / (2 * target)
        return ZoomPosition(scale: target, x: min(max(x, limit), 1 - limit), y: min(max(y, limit), 1 - limit))
    }

    /// Moves the photograph by `delta` points, within its edges.
    func panned(by delta: CGSize, in size: CGSize) -> ZoomPosition {
        let current = offset(in: size)
        return ZoomPosition(scale: scale, offset: CGPoint(x: current.x - delta.width, y: current.y - delta.height), in: size)
    }
}
