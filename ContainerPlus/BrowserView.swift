import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// The full tabbed web browser container: tab strip, navigation toolbar,
/// bookmarks, and the active web view.
struct BrowserContainerView: View {
    @ObservedObject var model: BrowserViewModel
    @State private var isImportingBookmarks = false

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
            Divider()
            NavigationToolbar(model: model, requestFileImport: { isImportingBookmarks = true })
            Divider()
            webArea
        }
        // Used by iPadOS bookmark import (macOS uses NSOpenPanel directly).
        .fileImporter(isPresented: $isImportingBookmarks,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.addBookmarks(BookmarkImporter.parse(fileAt: url))
            }
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
            }
            .buttonStyle(.borderless)

            AddressField(model: model)

            Button { model.bookmarkCurrentTab() } label: { Image(systemName: "star") }
                .buttonStyle(.borderless)
                .help("Bookmark this page")

            BookmarksMenu(model: model, requestFileImport: requestFileImport)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
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
    var requestFileImport: () -> Void

    var body: some View {
        Menu {
            Section("Import") {
                #if os(macOS)
                ForEach(BookmarkImporter.Source.allCases) { source in
                    Button("Import from \(source.rawValue)") {
                        model.addBookmarks(BookmarkImporter.promptImport(from: source))
                    }
                }
                #else
                Button("Import Bookmarks…") { requestFileImport() }
                #endif
            }
            if !model.bookmarks.isEmpty {
                Section("Bookmarks") {
                    ForEach(model.bookmarks) { bookmark in
                        Button {
                            model.openBookmark(bookmark, inNewTab: false)
                        } label: {
                            Text(bookmark.title.isEmpty ? bookmark.url : bookmark.title)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "book")
        }
        .fixedSize()
        .help("Bookmarks")
    }
}
