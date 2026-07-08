import Foundation
import WebKit
import Combine

struct Bookmark: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var url: String
}

/// Owns the set of open tabs for one browser pane. Bookmarks and the home
/// page live in the shared, persisted `BrowserStore`.
final class BrowserViewModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selectedTabID: UUID?

    let store = BrowserStore.shared

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    // MARK: Tab management

    /// Opens a new tab. When `url` is nil the home page is used.
    @discardableResult
    func newTab(url: URL? = nil, select: Bool = true) -> BrowserTab {
        let tab = BrowserTab(viewModel: self)
        tabs.append(tab)
        if select { selectedTabID = tab.id }
        tab.load(url ?? store.homePage)
        return tab
    }

    func goHome() {
        if let tab = selectedTab { tab.load(store.homePage) } else { newTab() }
    }

    /// Adopt a web view created by WebKit for a new window/tab.
    @discardableResult
    func adopt(webView: WKWebView, select: Bool) -> BrowserTab {
        let tab = BrowserTab(adopting: webView, viewModel: self)
        tabs.append(tab)
        if select { selectedTabID = tab.id }
        return tab
    }

    func select(_ tab: BrowserTab) { selectedTabID = tab.id }

    func close(_ tab: BrowserTab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.webView.stopLoading()
        tabs.remove(at: idx)
        if selectedTabID == tab.id {
            let newIndex = min(idx, tabs.count - 1)
            selectedTabID = tabs.indices.contains(newIndex) ? tabs[newIndex].id : nil
        }
        if tabs.isEmpty { newTab() }
    }

    func close(tabWith webView: WKWebView) {
        if let tab = tabs.first(where: { $0.webView === webView }) { close(tab) }
    }

    // MARK: Bookmarks (delegated to the shared store)

    func openBookmark(_ bookmark: Bookmark, inNewTab: Bool) {
        let url = BrowserTab.normalizedURL(from: bookmark.url)
        if inNewTab || selectedTab == nil {
            newTab(url: url)
        } else {
            selectedTab?.load(url)
        }
    }

    var isCurrentBookmarked: Bool {
        guard let tab = selectedTab else { return false }
        return store.isBookmarked(tab.urlString)
    }

    /// Toggle the bookmark for the current page.
    func toggleBookmarkCurrentTab() {
        guard let tab = selectedTab, !tab.urlString.isEmpty else { return }
        store.toggleBookmark(title: tab.title, url: tab.urlString)
    }
}
