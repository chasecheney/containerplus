import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// The full tabbed web browser container: tab strip, navigation toolbar,
/// bookmarks, and the active web view.
struct BrowserContainerView: View {
    @ObservedObject var model: BrowserViewModel
    @ObservedObject private var store = BrowserStore.shared
    @State private var isImportingBookmarks = false
    @State private var isEditingHome = false
    @State private var homeDraft = ""
    @State private var showingBookmarksManager = false
    @State private var confirmClearAll = false

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
            Divider()
            NavigationToolbar(model: model,
                              requestFileImport: { isImportingBookmarks = true },
                              requestEditHome: {
                                  homeDraft = store.homePage.absoluteString
                                  isEditingHome = true
                              },
                              requestManageBookmarks: { showingBookmarksManager = true },
                              requestClearAllBookmarks: { confirmClearAll = true })
            Divider()
            webArea
        }
        // Used by iPadOS bookmark import (macOS uses NSOpenPanel directly).
        .fileImporter(isPresented: $isImportingBookmarks,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.addBookmarks(BookmarkImporter.parse(fileAt: url))
            }
        }
        .alert("Home Page", isPresented: $isEditingHome) {
            TextField("https://example.com", text: $homeDraft)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            Button("Save") { store.setHomePage(homeDraft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New tabs and the Home button open this page.")
        }
        .confirmationDialog("Remove all \(store.bookmarks.count) bookmarks? This can't be undone.",
                            isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Clear All Bookmarks", role: .destructive) { store.clearBookmarks() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingBookmarksManager) {
            BookmarksManagerView(model: model)
        }
    }

    @ViewBuilder
    private var webArea: some View {
        if let tab = model.selectedTab {
            // Keep every tab's web view alive but only show the selected one,
            // so background tabs keep loading / playing.
            ZStack {
                ForEach(model.tabs) { t in
                    WebViewRepresentable(webView: t.webView)
                        .opacity(t.id == tab.id ? 1 : 0)
                        .allowsHitTesting(t.id == tab.id)
                }
            }
        } else {
            Palette.windowBackground
        }
    }
}

// MARK: - Tab strip

private struct TabStrip: View {
    @ObservedObject var model: BrowserViewModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.tabs) { tab in
                        TabChip(tab: tab,
                                isSelected: tab.id == model.selectedTabID,
                                onSelect: { model.select(tab) },
                                onClose: { model.close(tab) })
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }

            Button {
                model.newTab(url: URL(string: "https://www.google.com")!)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Tab")
            .padding(.horizontal, 8)
        }
        .background(.bar)
    }
}

private struct TabChip: View {
    @ObservedObject var tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if tab.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
            } else {
                Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(tab.title)
                .lineLimit(1)
                .font(.system(size: 12))
                .frame(maxWidth: 150, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Close Tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Palette.selectedControl : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Navigation toolbar

private struct NavigationToolbar: View {
    @ObservedObject var model: BrowserViewModel
    var requestFileImport: () -> Void
    var requestEditHome: () -> Void
    var requestManageBookmarks: () -> Void
    var requestClearAllBookmarks: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                Button { model.selectedTab?.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!(model.selectedTab?.canGoBack ?? false))
                    .help("Back")
                Button { model.selectedTab?.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!(model.selectedTab?.canGoForward ?? false))
                    .help("Forward")
                Button { model.selectedTab?.reloadOrStop() } label: {
                    Image(systemName: (model.selectedTab?.isLoading ?? false) ? "xmark" : "arrow.clockwise")
                }
                .help("Reload")
                Button { model.goHome() } label: { Image(systemName: "house") }
                    .help("Home")
            }
            .buttonStyle(.borderless)

            AddressField(model: model)

            StarButton(model: model)

            BookmarksMenu(model: model,
                          requestFileImport: requestFileImport,
                          requestEditHome: requestEditHome,
                          requestManageBookmarks: requestManageBookmarks,
                          requestClearAllBookmarks: requestClearAllBookmarks)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Star that reflects whether the current page is bookmarked and toggles it.
private struct StarButton: View {
    @ObservedObject var model: BrowserViewModel

    var body: some View {
        // Observing the tab keeps the star in sync as the page navigates;
        // switching tabs re-renders this because `model` publishes the change.
        if let tab = model.selectedTab {
            StarButtonInner(tab: tab)
        } else {
            Image(systemName: "star").foregroundStyle(.secondary)
        }
    }
}

private struct StarButtonInner: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var store = BrowserStore.shared

    var body: some View {
        let bookmarked = store.isBookmarked(tab.urlString)
        Button {
            store.toggleBookmark(title: tab.title, url: tab.urlString)
        } label: {
            Image(systemName: bookmarked ? "star.fill" : "star")
                .foregroundStyle(bookmarked ? Color.yellow : Color.primary)
        }
        .buttonStyle(.borderless)
        .disabled(tab.urlString.isEmpty)
        .help(bookmarked ? "Remove bookmark" : "Bookmark this page")
    }
}

private struct AddressField: View {
    @ObservedObject var model: BrowserViewModel

    var body: some View {
        if let tab = model.selectedTab {
            AddressFieldInner(tab: tab)
        } else {
            TextField("Search or enter address", text: .constant(""))
                .textFieldStyle(.roundedBorder)
                .disabled(true)
        }
    }
}

private struct AddressFieldInner: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        HStack(spacing: 6) {
            TextField("Search or enter address", text: $tab.addressField)
                .textFieldStyle(.roundedBorder)
                .onSubmit { tab.submitAddress() }
            if tab.isLoading {
                ProgressView(value: tab.estimatedProgress)
                    .frame(width: 60)
            }
        }
    }
}

// MARK: - Bookmarks

private struct BookmarksMenu: View {
    @ObservedObject var model: BrowserViewModel
    @ObservedObject private var store = BrowserStore.shared
    var requestFileImport: () -> Void
    var requestEditHome: () -> Void
    var requestManageBookmarks: () -> Void
    var requestClearAllBookmarks: () -> Void

    /// Cap the inline list so a big import doesn't create a giant menu.
    private let inlineLimit = 12

    var body: some View {
        Menu {
            Section("Home Page") {
                Button {
                    if let tab = model.selectedTab, !tab.urlString.isEmpty {
                        store.setHomePage(tab.urlString)
                    }
                } label: {
                    Label("Set current page as Home", systemImage: "house")
                }
                .disabled(model.selectedTab?.urlString.isEmpty ?? true)

                Button {
                    requestEditHome()
                } label: {
                    Label("Change home page…", systemImage: "pencil")
                }
            }

            Section("Import") {
                #if os(macOS)
                ForEach(BookmarkImporter.Source.allCases) { source in
                    Button("Import from \(source.rawValue)") {
                        store.addBookmarks(BookmarkImporter.promptImport(from: source))
                    }
                }
                #else
                Button("Import Bookmarks…") { requestFileImport() }
                #endif
            }

            if !store.bookmarks.isEmpty {
                Section("Bookmarks (\(store.bookmarks.count))") {
                    ForEach(store.bookmarks.prefix(inlineLimit)) { bookmark in
                        Button {
                            model.openBookmark(bookmark, inNewTab: false)
                        } label: {
                            Text(bookmark.title.isEmpty ? bookmark.url : bookmark.title)
                        }
                    }
                }
                Section {
                    Button {
                        requestManageBookmarks()
                    } label: {
                        Label("Manage Bookmarks…", systemImage: "list.bullet")
                    }
                    Button(role: .destructive) {
                        requestClearAllBookmarks()
                    } label: {
                        Label("Clear All Bookmarks", systemImage: "trash")
                    }
                }
            }
        } label: {
            Image(systemName: "book")
        }
        .fixedSize()
        .help("Bookmarks & Home")
    }
}

// MARK: - Bookmarks manager

/// A full editor for the (potentially large) bookmark list: search, open,
/// rename/edit URL, delete individually, and clear all.
private struct BookmarksManagerView: View {
    @ObservedObject var model: BrowserViewModel
    @ObservedObject private var store = BrowserStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var editing: Bookmark?
    @State private var draftTitle = ""
    @State private var draftURL = ""
    @State private var confirmClearAll = false

    private var filtered: [Bookmark] {
        guard !search.isEmpty else { return store.bookmarks }
        return store.bookmarks.filter {
            $0.title.localizedCaseInsensitiveContains(search)
            || $0.url.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bookmarks (\(store.bookmarks.count))").font(.headline)
                Spacer()
                Button(role: .destructive) { confirmClearAll = true } label: {
                    Text("Clear All")
                }
                .disabled(store.bookmarks.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            TextField("Search bookmarks", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.top, 8)

            if filtered.isEmpty {
                Spacer()
                Text(store.bookmarks.isEmpty ? "No bookmarks yet." : "No matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(filtered) { bookmark in
                        row(bookmark)
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        .alert("Edit Bookmark", isPresented: Binding(
            get: { editing != nil },
            set: { if !$0 { editing = nil } }
        )) {
            TextField("Title", text: $draftTitle)
            TextField("URL", text: $draftURL)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            Button("Save") {
                if let editing { store.updateBookmark(id: editing.id, title: draftTitle, url: draftURL) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove all \(store.bookmarks.count) bookmarks? This can't be undone.",
                            isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Clear All Bookmarks", role: .destructive) { store.clearBookmarks() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ bookmark: Bookmark) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.title.isEmpty ? bookmark.url : bookmark.title)
                    .lineLimit(1)
                Text(bookmark.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.openBookmark(bookmark, inNewTab: true)
                dismiss()
            } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless)
                .help("Open in new tab")
            Button {
                startEdit(bookmark)
            } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit")
            Button(role: .destructive) {
                store.removeBookmark(bookmark)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
        }
        .contentShape(Rectangle())
    }

    private func startEdit(_ bookmark: Bookmark) {
        draftTitle = bookmark.title
        draftURL = bookmark.url
        editing = bookmark
    }
}
