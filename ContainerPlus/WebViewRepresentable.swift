import SwiftUI
import WebKit
#if os(macOS)
import AppKit
import QuartzCore
#endif

/// Wraps an *existing* WKWebView so that SwiftUI can display it without
/// recreating it on every state change. Both the Plex container and each
/// browser tab own their WKWebView for the lifetime of the session, which is
/// what keeps cookies, scroll position and playback state intact.
///
/// On macOS the web view is embedded in a container that resizes it with
/// Core Animation implicit animations disabled. Without this, live-resizing
/// the split divider makes the web content "ghost" (a trailing afterimage),
/// because the layer bounds change animates every frame.
#if os(macOS)
struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WebContainerView {
        let container = WebContainerView()
        container.embed(webView)
        return container
    }

    func updateNSView(_ nsView: WebContainerView, context: Context) {}
}

final class WebContainerView: NSView {
    private weak var web: WKWebView?

    func embed(_ web: WKWebView) {
        self.web = web
        wantsLayer = true
        web.autoresizingMask = []
        web.frame = bounds
        addSubview(web)
    }

    override func layout() {
        // Resize the web view without the implicit bounds/position animation
        // that causes ghosting during a live divider drag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        super.layout()
        web?.frame = bounds
        CATransaction.commit()
    }
}
#else
struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

extension WKWebsiteDataStore {
    /// Shared persistent store so authentication cookies survive relaunches.
    static let containerPlus = WKWebsiteDataStore.default()
}
