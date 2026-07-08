import SwiftUI
import WebKit

/// Wraps an *existing* WKWebView so that SwiftUI can display it without
/// recreating it on every state change. Both the Plex container and each
/// browser tab own their WKWebView for the lifetime of the session, which is
/// what keeps cookies, scroll position and playback state intact.
///
/// The representable is `NSViewRepresentable` on macOS and `UIViewRepresentable`
/// on iPadOS — the wrapped WKWebView is identical on both platforms.
#if os(macOS)
struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
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
