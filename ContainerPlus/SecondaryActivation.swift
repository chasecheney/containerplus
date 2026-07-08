import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// An invisible, click-through helper that installs a *secondary activation*
/// gesture on its SwiftUI ancestor view — a right-click on macOS, a long-press
/// on iPadOS.
///
/// Why the ancestor and not this view? A `WKWebView` consumes SwiftUI gestures
/// layered on top of it, which is why a plain `.contextMenu` / swipe never
/// fires over web content. By attaching a native gesture recognizer to the
/// common ancestor (and recognizing simultaneously, without cancelling), the
/// gesture fires reliably over the web view while normal clicks/taps still
/// reach it untouched.
struct SecondaryActivationView {
    let onActivate: () -> Void
}

#if os(macOS)
extension SecondaryActivationView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = PassthroughNSView()
        context.coordinator.onActivate = onActivate
        view.onAttach = { [weak coordinator = context.coordinator] host in
            guard let host, let coordinator, !coordinator.installed else { return }
            let recognizer = NSClickGestureRecognizer(target: coordinator,
                                                      action: #selector(Coordinator.fire))
            recognizer.buttonMask = 0x2 // secondary (right) mouse button
            recognizer.numberOfClicksRequired = 1
            recognizer.delegate = coordinator
            recognizer.delaysPrimaryMouseButtonEvents = false
            host.addGestureRecognizer(recognizer)
            coordinator.installed = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onActivate = onActivate
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var onActivate: (() -> Void)?
        var installed = false
        @objc func fire() { onActivate?() }
        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool { true }
    }
}

private final class PassthroughNSView: NSView {
    var onAttach: ((NSView?) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // click-through
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onAttach?(superview)
    }
}
#else
extension SecondaryActivationView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = PassthroughUIView()
        context.coordinator.onActivate = onActivate
        view.onAttach = { [weak coordinator = context.coordinator] host in
            guard let host, let coordinator, !coordinator.installed else { return }
            let recognizer = UILongPressGestureRecognizer(target: coordinator,
                                                          action: #selector(Coordinator.fire(_:)))
            recognizer.minimumPressDuration = 0.5
            recognizer.delegate = coordinator
            host.addGestureRecognizer(recognizer)
            coordinator.installed = true
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onActivate = onActivate
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onActivate: (() -> Void)?
        var installed = false
        @objc func fire(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { onActivate?() }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

private final class PassthroughUIView: UIView {
    var onAttach: ((UIView?) -> Void)?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil } // click-through
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        onAttach?(superview)
    }
}
#endif
