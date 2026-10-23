import SwiftUI
import AppKit

/// Zoom no editor do Mac: pinch no trackpad à volta do cursor, deslocar com dois dedos (ou a roda do rato),
/// arrastar quando a ferramenta não usa o rato, e duplo clique para ampliar ou ajustar.
struct EditZoom<Content: View>: View {
    @Binding var position: ZoomPosition
    /// Com o recorte, as máscaras, a remoção e a divisão antes/depois, arrastar edita: aí desloca-se só com o trackpad.
    var dragPans: Bool
    /// VoiceOver: ampliar, reduzir, ajustar.
    var actionNames: [String]
    @ViewBuilder var content: () -> Content
    @State private var pinchStart: ZoomPosition?
    @State private var dragStart: ZoomPosition?
    @State private var viewport = CGSize.zero
    @State private var hovering = false
    @State private var monitor: Any?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let offset = position.offset(in: size)
            content()
                .frame(width: size.width, height: size.height)
                .scaleEffect(position.scale, anchor: .topLeading)
                .offset(x: -offset.x, y: -offset.y)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        let start = pinchStart ?? position
                        pinchStart = start
                        let anchor = CGPoint(x: value.startAnchor.x * size.width, y: value.startAnchor.y * size.height)
                        position = start.zoomed(to: start.scale * value.magnification, around: anchor, in: size)
                    }
                    .onEnded { _ in pinchStart = nil })
                .simultaneousGesture(DragGesture()
                    .onChanged { value in
                        let start = dragStart ?? position
                        dragStart = start
                        position = start.panned(by: value.translation, in: size)
                    }
                    .onEnded { _ in dragStart = nil },
                    including: dragPans && position.scale > 1 ? .all : .subviews)
                .simultaneousGesture(SpatialTapGesture(count: 2)
                    .onEnded { value in
                        withAnimation(Motion.snappy) {
                            position = position.scale > 1.01 ? ZoomPosition() : position.zoomed(to: 2.5, around: value.location, in: size)
                        }
                    },
                    including: dragPans ? .all : .subviews)
                .onHover { hovering = $0 }
                .onAppear { viewport = size }
                .onChange(of: size) { _, newSize in viewport = newSize }
                .accessibilityElement(children: .contain)
                .accessibilityValue(String(format: "%.1f×", position.scale))
                .accessibilityAction(named: actionNames[0]) { step(1.5) }
                .accessibilityAction(named: actionNames[1]) { step(1 / 1.5) }
                .accessibilityAction(named: actionNames[2]) { step(0) }
        }
        .onAppear(perform: watchScrolling)
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    private func step(_ factor: CGFloat) {
        withAnimation(Motion.snappy) { position = position.stepped(factor) }
    }

    /// O SwiftUI do macOS 14 não dá os deslocamentos do trackpad; só se consomem com o cursor por cima e a foto ampliada.
    private func watchScrolling() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            let delta = CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor)
            let used = MainActor.assumeIsolated {
                guard hovering, position.scale > 1, viewport != .zero else { return false }
                position = position.panned(by: delta, in: viewport)
                return true
            }
            return used ? nil : event
        }
    }
}
