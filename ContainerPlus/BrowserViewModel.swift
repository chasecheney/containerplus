import Foundation
import WebKit
import Combine

struct Bookmark: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var url: String
}

/// Owns the set of open tabs and the imported bookmarks for one browser pane.
final class BrowserViewModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selectedTabID: UUID?
    @Published var bookmarks: [Bookmark] = []

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    // MARK: Tab management

    @discardableResult
    func newTab(url: URL? = nil, select: Bool = true) -> BrowserTab {
        let tab = BrowserTab(viewModel: self)
        tabs.append(tab)
        if select { selectedTabID = tab.id }
        if let url { tab.load(url) }
        return tab
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
        if tabs.isEmpty { newTab(url: URL(string: "https://www.google.com")!) }
    }

    func close(tabWith webView: WKWebView) {
        if let tab = tabs.first(where: { $0.webView === webView }) { close(tab) }
    }

    // MARK: Bookmarks

    func openBookmark(_ bookmark: Bookmark, inNewTab: Bool) {
        let url = BrowserTab.normalizedURL(from: bookmark.url)
        if inNewTab || selectedTab == nil {
            newTab(url: url)
        } else {
            selectedTab?.load(url)
        }
    }

    func addBookmarks(_ new: [Bookmark]) {
        // De-dupe on URL.
        var seen = Set(bookmarks.map { $0.url })
        for b in new where !seen.contains(b.url) {
            bookmarks.append(b)
            seen.insert(b.url)
        }
    }

    func bookmarkCurrentTab() {
        guard let tab = selectedTab, !tab.urlString.isEmpty else { return }
        addBookmarks([Bookmark(title: tab.title, url: tab.urlString)])
    }
}
