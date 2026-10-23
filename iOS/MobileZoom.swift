import SwiftUI
import UIKit

/// Native touch recognizers with anchored pinch zoom, inertial scrolling and bounded panning.
struct MobileZoom<Content: View>: UIViewControllerRepresentable {
    @Binding var position: ZoomPosition
    var editingTouches = false
    var identifier = "mobile-zoom"
    /// VoiceOver actions: zoom in, zoom out, fit.
    var actionNames = ["Zoom in", "Zoom out", "Fit"]
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> MobileZoomController<Content> {
        let controller = MobileZoomController(rootView: content())
        configure(controller)
        return controller
    }

    func updateUIViewController(_ controller: MobileZoomController<Content>, context: Context) {
        controller.host.rootView = content()
        configure(controller)
        controller.apply(position)
    }

    private func configure(_ controller: MobileZoomController<Content>) {
        controller.onChange = { position = $0 }
        controller.scroll.accessibilityIdentifier = identifier
        controller.actionNames = actionNames
        // One finger remains available to crop, paint and move the before/after divider.
        let touches = editingTouches ? 2 : 1
        if controller.scroll.panGestureRecognizer.minimumNumberOfTouches != touches {
            controller.scroll.panGestureRecognizer.minimumNumberOfTouches = touches
        }
        if controller.doubleTap.isEnabled == editingTouches {
            controller.doubleTap.isEnabled = !editingTouches
        }
    }
}

final class MobileZoomController<Content: View>: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let host: UIHostingController<Content>
    let scroll = UIScrollView()
    private let zoomContent = UIView()
    let doubleTap = UITapGestureRecognizer()
    var onChange: ((ZoomPosition) -> Void)?
    var actionNames = ["Zoom in", "Zoom out", "Fit"] {
        didSet {
            guard actionNames != oldValue || scroll.accessibilityCustomActions == nil else { return }
            scroll.accessibilityCustomActions = zip(actionNames, [1.5, 1 / 1.5, 0] as [CGFloat]).map { name, factor in
                UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.step(factor) ?? false }
            }
        }
    }
    private var position = ZoomPosition()
    private var viewport = CGSize.zero
    private var applying = false
    private let pinch = UIPinchGestureRecognizer()
    private var pinchStartScale: CGFloat = 1
    private var pinchAnchor = CGPoint.zero

    init(rootView: Content) {
        host = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isMultipleTouchEnabled = true
        scroll.isMultipleTouchEnabled = true
        view.addSubview(scroll)
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.bounces = false
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        addChild(host)
        scroll.addSubview(zoomContent)
        zoomContent.addSubview(host.view)
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        host.view.isMultipleTouchEnabled = true
        // Keep the pinch anchor stable while SwiftUI refreshes the hosted editor.
        scroll.pinchGestureRecognizer?.isEnabled = false
        pinch.addTarget(self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        scroll.addGestureRecognizer(pinch)
        host.didMove(toParent: self)
        doubleTap.numberOfTapsRequired = 2
        // Single taps in the hosted editor should not wait for a possible second tap.
        doubleTap.delaysTouchesEnded = false
        doubleTap.addTarget(self, action: #selector(toggleZoom(_:)))
        scroll.addGestureRecognizer(doubleTap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0, size != viewport else { return }
        applying = true
        scroll.frame = view.bounds
        scroll.setZoomScale(1, animated: false)
        zoomContent.frame = CGRect(origin: .zero, size: size)
        host.view.frame = zoomContent.bounds
        scroll.contentSize = size
        viewport = size
        scroll.setZoomScale(position.scale, animated: false)
        scroll.contentOffset = position.offset(in: size)
        applying = false
        updateAccessibility()
    }

    func apply(_ newPosition: ZoomPosition) {
        guard pinch.state != .began, pinch.state != .changed, !scroll.isTracking, !scroll.isDragging, !scroll.isZooming, !scroll.isDecelerating else { return }
        guard newPosition != position else { return }
        position = newPosition
        guard viewport != .zero else { return }
        applying = true
        scroll.setZoomScale(position.scale, animated: false)
        scroll.contentOffset = position.offset(in: viewport)
        applying = false
        updateAccessibility()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return zoomContent
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        publish()
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { publish() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { publish() }

    private func publish() {
        guard !applying, viewport.width > 0, viewport.height > 0 else { return }
        let scale = min(max(scroll.zoomScale, 1), 6)
        position = ZoomPosition(scale: scale,
            x: (scroll.contentOffset.x + viewport.width / 2) / (viewport.width * scale),
            y: (scroll.contentOffset.y + viewport.height / 2) / (viewport.height * scale))
        if scale <= 1.001 { position = ZoomPosition() }
        updateAccessibility()
        onChange?(position)
    }

    private func updateAccessibility() {
        scroll.accessibilityValue = String(format: "%.2fx", position.scale)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other === scroll.panGestureRecognizer
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        let location = recognizer.location(in: view)
        if recognizer.state == .began {
            pinchStartScale = scroll.zoomScale
            pinchAnchor = CGPoint(x: (scroll.contentOffset.x + location.x) / pinchStartScale,
                                  y: (scroll.contentOffset.y + location.y) / pinchStartScale)
        }
        guard recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended else { return }
        let scale = min(max(pinchStartScale * recognizer.scale, 1), 6)
        applying = true
        scroll.setZoomScale(scale, animated: false)
        scroll.contentOffset = CGPoint(
            x: min(max(pinchAnchor.x * scale - location.x, 0), viewport.width * (scale - 1)),
            y: min(max(pinchAnchor.y * scale - location.y, 0), viewport.height * (scale - 1)))
        applying = false
        publish()
    }

    /// Zooms around the viewport centre; a factor of 0 fits the photograph.
    func step(_ factor: CGFloat) -> Bool {
        guard viewport.width > 0, viewport.height > 0 else { return false }
        let current = scroll.zoomScale
        let scale = factor == 0 ? 1 : min(max(current * factor, 1), 6)
        let centre = CGPoint(x: (scroll.contentOffset.x + viewport.width / 2) / current,
                             y: (scroll.contentOffset.y + viewport.height / 2) / current)
        applying = true
        scroll.setZoomScale(scale, animated: false)
        scroll.contentOffset = CGPoint(
            x: min(max(centre.x * scale - viewport.width / 2, 0), viewport.width * (scale - 1)),
            y: min(max(centre.y * scale - viewport.height / 2, 0), viewport.height * (scale - 1)))
        applying = false
        publish()
        return true
    }

    @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
        if scroll.zoomScale > 1.01 {
            scroll.setZoomScale(1, animated: true)
        } else {
            let point = recognizer.location(in: zoomContent)
            let size = CGSize(width: viewport.width / 2.5, height: viewport.height / 2.5)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
        }
    }
}
