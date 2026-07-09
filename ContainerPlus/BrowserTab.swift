import Foundation
import WebKit
import Combine

/// A single browser tab. Owns its WKWebView and observes it via KVO so the
/// SwiftUI toolbar (title, address, back/forward, progress) stays in sync.
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView

    @Published var title: String = "New Tab"
    @Published var urlString: String = ""
    @Published var addressField: String = ""
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0

    weak var viewModel: BrowserViewModel?
    private var observations: [NSKeyValueObservation] = []

    /// Create a tab wrapping a brand-new web view.
    init(viewModel: BrowserViewModel?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .containerPlus
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.viewModel = viewModel
        super.init()
        finishSetup()
    }

    /// Adopt a web view handed to us by `createWebViewWith` (window.open /
    /// target=_blank). We must NOT create a new WKWebView here — the returned
    /// instance is what WebKit will drive.
    init(adopting webView: WKWebView, viewModel: BrowserViewModel?) {
        self.webView = webView
        self.viewModel = viewModel
        super.init()
        finishSetup()
    }

    private func finishSetup() {
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observe()
    }

    private func observe() {
        observations = [
            webView.observe(\.title, options: [.initial, .new]) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.title = (wv.title?.isEmpty == false ? wv.title! : "New Tab") }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    let s = wv.url?.absoluteString ?? ""
                    self?.urlString = s
                    self?.addressField = s
                }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.canGoForward = wv.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.isLoading = wv.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.estimatedProgress = wv.estimatedProgress }
            },
        ]
    }

    // MARK: Navigation helpers

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reloadOrStop() { if isLoading { webView.stopLoading() } else { webView.reload() } }

    /// Turn whatever the user typed into a URL: navigate if it looks like one,
    /// otherwise run a Google search.
    func submitAddress() {
        let text = addressField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        load(BrowserTab.normalizedURL(from: text))
    }

    static func normalizedURL(from text: String) -> URL {
        if let url = URL(string: text), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        // Looks like a bare domain (has a dot, no spaces) → prepend https.
        if !text.contains(" "), text.contains("."),
           let url = URL(string: "https://\(text)") {
            return url
        }
        // .alphanumerics so "&", "=", "+" etc. in the query are escaped.
        let q = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
        return URL(string: "https://www.google.com/search?q=\(q)")!
    }

    deinit { observations.forEach { $0.invalidate() } }
}

// MARK: - Delegates

extension BrowserTab: WKNavigationDelegate, WKUIDelegate {
    /// New windows (window.open, target=_blank, cmd-click) open as a new tab.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let vm = viewModel else { return nil }
        let newWebView = WKWebView(frame: .zero, configuration: configuration)
        let tab = vm.adopt(webView: newWebView, select: true)
        // If WebKit didn't auto-load (some target=_blank cases), load the URL.
        if let url = navigationAction.request.url, navigationAction.targetFrame == nil {
            newWebView.load(URLRequest(url: url))
        }
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        viewModel?.close(tabWith: webView)
    }
}
