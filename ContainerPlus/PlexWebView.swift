import SwiftUI
import WebKit

/// Owns the WKWebView for the Plex Web container. The view is "locked": there
/// is no address bar, and off-site navigations (e.g. clicking an external link)
/// are kept inside the same web view rather than spawning windows.
///
/// Authentication is remembered via the shared persistent website data store
/// (cookies + local storage). The last visited Plex URL is additionally cached
/// in the keychain so a fresh install can restore the user to where they were.
final class PlexViewModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let homeURL = URL(string: "https://app.plex.tv/desktop")!
    private static let keychainAccount = "plex.lastURL"

    let webView: WKWebView
    @Published var isLoading = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .containerPlus
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = nil // use the system Safari UA for best Plex compatibility
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self

        let start = KeychainHelper.get(Self.keychainAccount)
            .flatMap(URL.init(string:)) ?? Self.homeURL
        webView.load(URLRequest(url: start))
    }

    /// Long-press action: return to the Plex home page.
    func goHome() {
        webView.load(URLRequest(url: Self.homeURL))
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        if let url = webView.url { scheduleSaveLastURL(url.absoluteString) }
    }

    /// Debounced, off-main keychain write so we don't do synchronous keychain
    /// I/O on the main thread on every single navigation.
    private var saveTask: Task<Void, Never>?
    private func scheduleSaveLastURL(_ urlString: String) {
        saveTask?.cancel()
        saveTask = Task.detached {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            KeychainHelper.set(urlString, for: Self.keychainAccount)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    // MARK: WKUIDelegate — keep everything in one locked view.

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank / window.open → load in the same view instead of a new window.
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

struct PlexContainerView: View {
    @ObservedObject var model: PlexViewModel

    var body: some View {
        WebViewRepresentable(webView: model.webView)
            .overlay(alignment: .top) {
                if model.isLoading {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                }
            }
        // "Refresh to Plex Home" now lives in the pane's floating menu,
        // so it no longer competes with the web view's own gestures.
    }
}
