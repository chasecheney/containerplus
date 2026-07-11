import SwiftUI
import UniformTypeIdentifiers

// MARK: - View model

@MainActor
final class StoryReaderViewModel: ObservableObject {
    enum Phase: Equatable {
        case empty
        case loading
        case ready
        case error(String)
    }

    enum Filter: Hashable {
        case all
        case favorites
        case tag(String)
        var label: String {
            switch self {
            case .all: return "All Stories"
            case .favorites: return "Favorites"
            case .tag(let t): return "#\(t)"
            }
        }
    }

    @Published private(set) var phase: Phase = .empty
    @Published private(set) var bundleName = ""
    @Published private(set) var allTags: [String] = []
    @Published private(set) var visibleSeries: [StorySeries] = []
    @Published private(set) var filter: Filter = .all
    @Published var searchText = "" { didSet { applyFilter() } }
    @Published var selectedStem: String?

    private var series: [StorySeries] = []
    private var storiesByStem: [String: StoryItem] = [:]
    private var entriesByStem: [String: StoryBundle.ManifestEntry] = [:]
    private var blobStart: UInt64 = 0
    private var accessURL: URL?      // security-scoped, access started for the session

    private var states: [String: StoryReadingState] = [:]

    private let bookmarkKey = "storyreader.bundleBookmark"
    private let statesKey = "storyreader.readingStates"

    nonisolated init() {}

    // MARK: Lifecycle

    func start() {
        loadStates()
        guard case .empty = phase else { return }
        if let data = UserDefaults.standard.data(forKey: bookmarkKey),
           let url = Self.resolveBookmark(data) {
            open(url: url, persistBookmark: false)
        }
    }

    // MARK: Opening a bundle

    func open(url: URL, persistBookmark: Bool = true) {
        phase = .loading
        let started = url.startAccessingSecurityScopedResource()
        do {
            let (manifest, blobStart) = try StoryBundle.readManifest(at: url)
            // Swap in the new access URL (release the previous one).
            if let old = accessURL, old != url { old.stopAccessingSecurityScopedResource() }
            accessURL = started ? url : accessURL
            self.blobStart = blobStart
            bundleName = url.deletingPathExtension().lastPathComponent
            buildIndex(from: manifest.entries)
            if persistBookmark, let data = Self.makeBookmark(url) {
                UserDefaults.standard.set(data, forKey: bookmarkKey)
            }
            phase = .ready
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            phase = .error(error.localizedDescription)
        }
    }

    private func buildIndex(from entries: [StoryBundle.ManifestEntry]) {
        entriesByStem = [:]
        storiesByStem = [:]
        var byKey: [String: (title: String, items: [StoryItem])] = [:]
        var tagSet = Set<String>()

        for entry in entries {
            entriesByStem[entry.stem] = entry
            let parsed = StoryFilenameParser.parse(stem: entry.stem)
            let seriesKey = StoryFilenameParser.baseTitle(parsed.title).lowercased()
            let item = StoryItem(id: parsed.storyID ?? entry.stem,
                                 stem: entry.stem,
                                 title: parsed.title,
                                 seriesKey: seriesKey,
                                 tags: parsed.tags,
                                 size: Int(entry.size))
            storiesByStem[entry.stem] = item
            parsed.tags.forEach { tagSet.insert($0) }
            if byKey[seriesKey] == nil {
                byKey[seriesKey] = (StoryFilenameParser.baseTitle(parsed.title), [])
            }
            byKey[seriesKey]?.items.append(item)
        }

        series = byKey.map { key, value in
            StorySeries(id: key,
                        title: value.title,
                        stories: value.items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        allTags = tagSet.sorted()
        applyFilter()
    }

    // MARK: Filtering

    func setFilter(_ newFilter: Filter) {
        filter = newFilter
        applyFilter()
    }

    private func applyFilter() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        visibleSeries = series.compactMap { group in
            let matches = group.stories.filter { story in
                let tagOK: Bool
                switch filter {
                case .all: tagOK = true
                case .favorites: tagOK = state(forID: story.id).favorite
                case .tag(let t): tagOK = story.tags.contains(t)
                }
                guard tagOK else { return false }
                if query.isEmpty { return true }
                return story.title.lowercased().contains(query)
                    || story.tags.contains { $0.contains(query) }
                    || group.title.lowercased().contains(query)
            }
            return matches.isEmpty ? nil : StorySeries(id: group.id, title: group.title, stories: matches)
        }
    }

    // MARK: Reading

    func story(forStem stem: String) -> StoryItem? { storiesByStem[stem] }

    func body(forStem stem: String) async throws -> String {
        guard let url = accessURL, let entry = entriesByStem[stem] else {
            throw StoryBundle.BundleError.unreadable
        }
        let start = blobStart
        return try await Task.detached(priority: .userInitiated) {
            try StoryBundle.readBody(at: url, entry: entry, blobStart: start)
        }.value
    }

    /// The previous/next part within the same series.
    func neighbor(ofStem stem: String, offset: Int) -> StoryItem? {
        guard let story = storiesByStem[stem],
              let group = series.first(where: { $0.id == story.seriesKey }),
              let idx = group.stories.firstIndex(of: story) else { return nil }
        let target = idx + offset
        return group.stories.indices.contains(target) ? group.stories[target] : nil
    }

    // MARK: Reading state (local, per story id)

    func state(forID id: String) -> StoryReadingState { states[id] ?? StoryReadingState() }

    func savePosition(id: String, fraction: Double) {
        var s = states[id] ?? StoryReadingState()
        s.position = fraction
        if fraction > 0.92 { s.read = true }
        states[id] = s
        persistStates()
    }

    func toggleFavorite(id: String) {
        objectWillChange.send()   // states isn't @Published; refresh the star
        var s = states[id] ?? StoryReadingState()
        s.favorite.toggle()
        states[id] = s
        persistStates()
        if filter == .favorites { applyFilter() }
    }

    func setRead(id: String, _ read: Bool) {
        objectWillChange.send()
        var s = states[id] ?? StoryReadingState()
        s.read = read
        states[id] = s
        persistStates()
    }

    private func loadStates() {
        if let data = UserDefaults.standard.data(forKey: statesKey),
           let decoded = try? JSONDecoder().decode([String: StoryReadingState].self, from: data) {
            states = decoded
        }
    }

    private func persistStates() {
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: statesKey)
        }
    }

    // MARK: Security-scoped bookmarks (cross-platform)

    private static func makeBookmark(_ url: URL) -> Data? {
        #if os(macOS)
        return try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        #if os(macOS)
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
    }
}

// MARK: - Container view

struct StoryReaderContainerView: View {
    @ObservedObject var model: StoryReaderViewModel
    @State private var importing = false

    var body: some View {
        ZStack {
            Palette.windowBackground
            content
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "storybundle") ?? .data, .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.open(url: url)
            }
        }
        .onAppear { model.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .empty:
            OpenLibraryView { importing = true }
        case .loading:
            VStack(spacing: 12) { ProgressView(); Text("Opening library…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.yellow)
                Text(message).multilineTextAlignment(.center).frame(maxWidth: 340)
                Button("Open Library…") { importing = true }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        case .ready:
            if let stem = model.selectedStem {
                StoryReaderPage(model: model, stem: stem)
            } else {
                StoryListPane(model: model, openLibrary: { importing = true })
            }
        }
    }
}

private struct OpenLibraryView: View {
    let openLibrary: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical.fill").font(.system(size: 54)).foregroundStyle(.brown)
            Text("Story Reader").font(.title2).bold()
            Text("Open a Story Reader library bundle (.storybundle) to browse and read.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            Button("Open Library…") { openLibrary() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

// MARK: - Story list

private struct StoryListPane: View {
    @ObservedObject var model: StoryReaderViewModel
    let openLibrary: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            searchBar
            if model.visibleSeries.isEmpty {
                Text("No stories match.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.visibleSeries) { group in
                        Section(group.stories.count > 1 ? group.title : "") {
                            ForEach(group.stories) { story in
                                StoryRow(model: model, story: story)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selectedStem = story.stem }
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.plain)
                #endif
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Menu {
                Button { model.setFilter(.all) } label: { Label("All Stories", systemImage: "books.vertical") }
                Button { model.setFilter(.favorites) } label: { Label("Favorites", systemImage: "star") }
                if !model.allTags.isEmpty {
                    Section("Tags") {
                        ForEach(model.allTags, id: \.self) { tag in
                            Button { model.setFilter(.tag(tag)) } label: { Text("#\(tag)") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(model.filter.label).fontWeight(.semibold).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()

            Spacer()

            Button { openLibrary() } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Open a different library")
        }
        .padding(.leading, 12).padding(.vertical, 8)
        .padding(.trailing, containerPickerReservedWidth)
        .background(.bar)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search titles and tags", text: $model.searchText)
                .textFieldStyle(.plain)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Palette.selectedControl, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct StoryRow: View {
    @ObservedObject var model: StoryReaderViewModel
    let story: StoryItem

    var body: some View {
        let s = model.state(forID: story.id)
        HStack(spacing: 10) {
            Image(systemName: s.read ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(s.read ? Color.accentColor : Color.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(story.title).lineLimit(1)
                if !story.tags.isEmpty {
                    Text(story.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if s.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
            if s.position > 0.01 && !s.read {
                Text("\(Int(s.position * 100))%").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Reader page

private struct StoryReaderPage: View {
    @ObservedObject var model: StoryReaderViewModel
    let stem: String

    @AppStorage("storyreader.fontSize") private var fontSize: Double = 17
    @AppStorage("storyreader.serif") private var serif = true
    @AppStorage("storyreader.theme") private var themeRaw = ReaderTheme.system.rawValue

    @State private var paragraphs: [String] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var scrolledID: Int?
    @State private var restored = false

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .system }
    private var story: StoryItem? { model.story(forStem: stem) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            Group {
                if loading {
                    ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.yellow)
                        Text(loadError).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
                } else {
                    readerScroll
                }
            }
            .background(theme.background ?? Palette.windowBackground)
        }
        .preferredColorScheme(theme.colorScheme)
        .task(id: stem) { await load() }
        .onDisappear { savePosition() }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { savePosition(); model.selectedStem = nil } label: {
                Label("Library", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            Text(story?.title ?? "").font(.headline).lineLimit(1)
            Spacer()

            if let prev = model.neighbor(ofStem: stem, offset: -1) {
                Button { savePosition(); model.selectedStem = prev.stem } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).help("Previous part")
            }
            if let next = model.neighbor(ofStem: stem, offset: 1) {
                Button { savePosition(); model.selectedStem = next.stem } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).help("Next part")
            }

            if let id = story?.id {
                Button { model.toggleFavorite(id: id) } label: {
                    Image(systemName: model.state(forID: id).favorite ? "star.fill" : "star")
                        .foregroundStyle(model.state(forID: id).favorite ? Color.yellow : Color.primary)
                }
                .buttonStyle(.borderless)
            }

            optionsMenu
        }
        .padding(.leading, 12).padding(.vertical, 8)
        .padding(.trailing, containerPickerReservedWidth)
        .background(.bar)
    }

    private var optionsMenu: some View {
        Menu {
            Section("Text Size") {
                Button("Smaller") { fontSize = max(12, fontSize - 1) }
                Button("Larger") { fontSize = min(32, fontSize + 1) }
            }
            Section("Font") {
                Picker("Font", selection: $serif) {
                    Text("Serif").tag(true)
                    Text("Sans-serif").tag(false)
                }
            }
            Section("Theme") {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(ReaderTheme.allCases) { t in Text(t.label).tag(t.rawValue) }
                }
            }
            if let id = story?.id {
                Section {
                    Button(model.state(forID: id).read ? "Mark as Unread" : "Mark as Read") {
                        model.setRead(id: id, !model.state(forID: id).read)
                    }
                }
            }
        } label: {
            Image(systemName: "textformat.size")
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var readerScroll: some View {
        GeometryReader { geo in
            let columnWidth = min(760, geo.size.width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: fontSize * 0.9) {
                    ForEach(paragraphs.indices, id: \.self) { i in
                        Text(paragraphs[i])
                            .font(.system(size: fontSize, design: serif ? .serif : .default))
                            .lineSpacing(fontSize * 0.32)
                            .foregroundStyle(theme.foreground ?? Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                    nextFooter
                }
                .scrollTargetLayout()
                .padding(.horizontal, 24).padding(.vertical, 20)
                .frame(width: columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition(id: $scrolledID, anchor: .top)
            .onChange(of: scrolledID) { _, _ in if restored { savePosition() } }
        }
    }

    @ViewBuilder
    private var nextFooter: some View {
        if let next = model.neighbor(ofStem: stem, offset: 1) {
            Button {
                savePosition()
                model.selectedStem = next.stem
            } label: {
                Label("Next: \(next.title)", systemImage: "arrow.right").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 24)
        }
    }

    private func load() async {
        loading = true
        loadError = nil
        restored = false
        do {
            let body = try await model.body(forStem: stem)
            paragraphs = Self.splitParagraphs(body)
            loading = false
            if let id = story?.id {
                let fraction = model.state(forID: id).position
                if fraction > 0.01, paragraphs.count > 1 {
                    scrolledID = min(paragraphs.count - 1, Int(fraction * Double(paragraphs.count)))
                }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            restored = true
        } catch {
            loading = false
            loadError = error.localizedDescription
        }
    }

    private func savePosition() {
        guard restored, let id = story?.id, let scrolled = scrolledID, paragraphs.count > 1 else { return }
        model.savePosition(id: id, fraction: Double(scrolled) / Double(paragraphs.count))
    }

    static func splitParagraphs(_ body: String) -> [String] {
        body.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
