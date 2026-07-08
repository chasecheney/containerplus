import Foundation
import Combine

/// App-wide, persisted browser settings shared by every browser pane:
/// the bookmark list and the home page. Backed by `UserDefaults` so both
/// panes stay in sync and everything survives relaunch.
final class BrowserStore: ObservableObject {
    static let shared = BrowserStore()

    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var homePage: URL = URL(string: "https://www.google.com")!

    private let bookmarksKey = "browser.bookmarks"
    private let homeKey = "browser.homePage"

    private init() {
        if let data = UserDefaults.standard.data(forKey: bookmarksKey),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = decoded
        }
        if let stored = UserDefaults.standard.string(forKey: homeKey),
           let url = URL(string: stored) {
            homePage = url
        }
    }

    // MARK: Bookmarks

    func isBookmarked(_ urlString: String) -> Bool {
        bookmarks.contains { $0.url == urlString }
    }

    /// Add if absent, remove if present. Returns the new bookmarked state.
    @discardableResult
    func toggleBookmark(title: String, url: String) -> Bool {
        guard !url.isEmpty else { return false }
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: index)
            persistBookmarks()
            return false
        }
        bookmarks.append(Bookmark(title: title.isEmpty ? url : title, url: url))
        persistBookmarks()
        return true
    }

    func addBookmarks(_ new: [Bookmark]) {
        var seen = Set(bookmarks.map { $0.url })
        for bookmark in new where !seen.contains(bookmark.url) {
            bookmarks.append(bookmark)
            seen.insert(bookmark.url)
        }
        persistBookmarks()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        persistBookmarks()
    }

    func clearBookmarks() {
        bookmarks.removeAll()
        persistBookmarks()
    }

    func updateBookmark(id: UUID, title: String, url: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        bookmarks[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks[index].url = trimmedURL
        persistBookmarks()
    }

    private func persistBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: bookmarksKey)
        }
    }

    // MARK: Home page

    func setHomePage(_ text: String) {
        let url = BrowserTab.normalizedURL(from: text)
        homePage = url
        UserDefaults.standard.set(url.absoluteString, forKey: homeKey)
    }
}
