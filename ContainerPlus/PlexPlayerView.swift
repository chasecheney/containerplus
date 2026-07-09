import SwiftUI
import AVKit
import AVFoundation

// MARK: - View model

@MainActor
final class PlexPlayerViewModel: ObservableObject {
    enum Phase: Equatable {
        case signedOut
        case linking(code: String)
        case loading(String)
        case browsing
        case error(String)
    }

    enum BrowseMode: Equatable {
        case home
        case library(PlexLibraryRef)
    }

    enum LibraryTab: String, CaseIterable, Identifiable {
        case recommended = "Recommended"
        case browse = "Browse"
        case playlists = "Playlists"
        var id: String { rawValue }
    }

    /// Load state for the (potentially large) Browse list. Distinguishes
    /// "waiting to connect" from "server is responding, downloading".
    enum LoadState: Equatable {
        case idle
        case connecting
        case downloading
        case ready
        case failed(String)
    }

    struct BrowseLevel: Identifiable {
        let id = UUID()
        let title: String
        var items: [PlexMetadata]
    }

    @Published private(set) var phase: Phase = .signedOut
    @Published private(set) var servers: [PlexResource] = []
    @Published private(set) var selectedServer: PlexResource?
    @Published private(set) var onDeck: [PlexMetadata] = []
    @Published private(set) var recentlyAdded: [PlexMetadata] = []
    @Published private(set) var sections: [PlexDirectory] = []
    @Published private(set) var serverLibraries: [String: [PlexDirectory]] = [:]

    // Library browsing
    @Published private(set) var mode: BrowseMode = .home
    @Published private(set) var stack: [BrowseLevel] = []
    @Published var libraryTab: LibraryTab = .browse
    @Published var sortField: PlexSortField = .name
    @Published var sortAscending = true
    @Published var tvEpisodes = false
    @Published private(set) var recommendedHubs: [PlexHub] = []
    @Published private(set) var browseItems: [PlexMetadata] = []
    @Published private(set) var playlists: [PlexMetadata] = []
    @Published private(set) var libraryLoadState: LoadState = .idle
    @Published private(set) var tabLoading = false

    // Player
    @Published var player: AVPlayer?
    @Published private(set) var nowPlayingTitle: String?
    @Published private(set) var nowPlayingItem: PlexMetadata?
    @Published var isPlayerMinimized = false
    @Published private(set) var isPlaying = false
    @Published private(set) var quality: PlexQuality = .original
    /// App-level playback volume (0…1), independent of the device volume.
    @Published private(set) var volume: Double = 1.0
    @Published private(set) var isMuted = false

    // Sheets
    @Published var showLibraryPicker = false
    @Published var infoItem: PlexMetadata?

    let api = PlexAPI()
    let prefs = PlexPreferences.shared
    private var baseURL: URL?
    private var serverToken: String?
    private var connectionCache: [String: (base: URL, token: String)] = [:]
    private var pollTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    // Play queue
    private var playQueue: [PlexMetadata] = []
    private var queueIndex = 0

    nonisolated init() {}

    private var authToken: String? {
        get { KeychainHelper.get("plex.authToken") }
        set {
            if let newValue { KeychainHelper.set(newValue, for: "plex.authToken") }
            else { KeychainHelper.delete("plex.authToken") }
        }
    }

    var currentLibrary: PlexLibraryRef? {
        if case .library(let ref) = mode { return ref }
        return nil
    }

    var isShowLibrary: Bool { currentLibrary?.type == "show" }

    var navTitle: String { currentLibrary?.title ?? "Home" }

    // MARK: Lifecycle / auth

    func start() {
        guard case .signedOut = phase else { return }
        if authToken != nil { Task { await connect() } }
    }

    func beginLinking() {
        pollTask?.cancel()
        pollTask = Task {
            do {
                let pin = try await api.createPin()
                phase = .linking(code: pin.code)
                SystemBrowser.open(api.linkPageURL)
                try await pollForToken(pinID: pin.id)
            } catch is CancellationError {
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    func reopenLinkPage() { SystemBrowser.open(api.linkPageURL) }

    func cancelLinking() {
        pollTask?.cancel()
        phase = .signedOut
    }

    func signOut() {
        pollTask?.cancel()
        authToken = nil
        KeychainHelper.delete("plex.lastConnection")
        baseURL = nil
        serverToken = nil
        connectionCache = [:]
        servers = []
        selectedServer = nil
        sections = []
        onDeck = []
        recentlyAdded = []
        serverLibraries = [:]
        mode = .home
        stack = []
        recommendedHubs = []
        browseItems = []
        playlists = []
        libraryLoadState = .idle
        closePlayer()
        phase = .signedOut
    }

    private func pollForToken(pinID: Int) async throws {
        for _ in 0..<150 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard let pin = try? await api.checkPin(id: pinID) else { continue }
            if let token = pin.authToken, !token.isEmpty {
                authToken = token
                await connect()
                return
            }
        }
        phase = .error("Timed out waiting for Plex sign-in.")
    }

    // MARK: Servers

    func connect() async {
        guard let token = authToken else { phase = .signedOut; return }

        // Fast path: reuse the last-good connection, validated with a quick
        // probe, and refresh the server list in the background.
        if let cached = loadCachedConnection(), let base = URL(string: cached.baseURL) {
            phase = .loading("Reconnecting to \(cached.serverName)…")
            if await api.probe(base: base, token: cached.token) {
                baseURL = base
                serverToken = cached.token
                connectionCache[cached.serverID] = (base, cached.token)
                await loadHome()
                Task { await refreshServers(preferredID: cached.serverID) }
                return
            }
        }

        phase = .loading("Finding your servers…")
        do {
            let all = try await api.resources(token: token).filter { $0.isServer }
            servers = all
            guard let first = all.first else {
                phase = .error("No Plex servers found on this account.")
                return
            }
            await select(server: first)
        } catch {
            phase = .error(classify(error))
        }
    }

    /// Refresh the server list without disturbing the active connection.
    private func refreshServers(preferredID: String?) async {
        guard let token = authToken,
              let all = try? await api.resources(token: token).filter({ $0.isServer }) else { return }
        servers = all
        if selectedServer == nil, let preferredID {
            selectedServer = all.first { $0.clientIdentifier == preferredID }
        }
    }

    private func loadCachedConnection() -> PlexCachedConnection? {
        guard let raw = KeychainHelper.get("plex.lastConnection"),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlexCachedConnection.self, from: data)
    }

    private func saveCachedConnection(serverID: String, name: String, base: URL, token: String) {
        connectionCache[serverID] = (base, token)
        let cached = PlexCachedConnection(serverID: serverID, serverName: name,
                                          baseURL: base.absoluteString, token: token)
        if let data = try? JSONEncoder().encode(cached), let raw = String(data: data, encoding: .utf8) {
            KeychainHelper.set(raw, for: "plex.lastConnection")
        }
    }

    private func connection(for serverID: String) async -> (base: URL, token: String)? {
        if let cached = connectionCache[serverID] { return cached }
        guard let server = servers.first(where: { $0.clientIdentifier == serverID }),
              let reachable = await api.reachableBaseURL(for: server) else { return nil }
        connectionCache[serverID] = reachable
        return reachable
    }

    func select(server: PlexResource) async {
        selectedServer = server
        phase = .loading("Connecting to \(server.name)…")
        guard let conn = await connection(for: server.clientIdentifier) else {
            phase = .error("Couldn't reach \(server.name).")
            return
        }
        baseURL = conn.base
        serverToken = conn.token
        saveCachedConnection(serverID: server.clientIdentifier, name: server.name, base: conn.base, token: conn.token)
        await loadHome()
    }

    func loadHome() async {
        guard let base = baseURL, let token = serverToken else { return }
        phase = .loading("Loading your library…")
        mode = .home
        stack = []
        async let deck = try? api.onDeck(base: base, token: token)
        async let recent = try? api.recentlyAdded(base: base, token: token)
        async let secs = try? api.sections(base: base, token: token)
        onDeck = await deck ?? []
        recentlyAdded = await recent ?? []
        sections = await secs ?? []
        phase = .browsing
    }

    func loadAllServerLibraries() {
        for server in servers where serverLibraries[server.clientIdentifier] == nil {
            Task {
                guard let conn = await connection(for: server.clientIdentifier) else { return }
                if let secs = try? await api.sections(base: conn.base, token: conn.token) {
                    serverLibraries[server.clientIdentifier] = secs
                }
            }
        }
    }

    func makeRef(server: PlexResource, section: PlexDirectory) -> PlexLibraryRef {
        PlexLibraryRef(serverID: server.clientIdentifier, serverName: server.name,
                       sectionKey: section.key, title: section.title, type: section.type)
    }

    // MARK: Home / library selection

    func selectHome() {
        showLibraryPicker = false
        Task { await loadHome() }
    }

    func select(library ref: PlexLibraryRef) {
        showLibraryPicker = false
        Task {
            phase = .loading("Loading \(ref.title)…")
            guard let conn = await connection(for: ref.serverID) else {
                phase = .error("Couldn't reach \(ref.serverName).")
                return
            }
            baseURL = conn.base
            serverToken = conn.token
            selectedServer = servers.first { $0.clientIdentifier == ref.serverID }
            saveCachedConnection(serverID: ref.serverID, name: ref.serverName, base: conn.base, token: conn.token)
            mode = .library(ref)
            stack = []
            sortField = .name
            sortAscending = true
            tvEpisodes = false
            recommendedHubs = []
            browseItems = []
            playlists = []
            libraryTab = .recommended
            phase = .browsing
            loadLibraryTab()
        }
    }

    func openHomeSection(_ section: PlexDirectory) {
        guard let server = selectedServer else { return }
        select(library: makeRef(server: server, section: section))
    }

    // MARK: Library tabs

    func setLibraryTab(_ tab: LibraryTab) {
        libraryTab = tab
        loadLibraryTab()
    }

    func loadLibraryTab() {
        switch libraryTab {
        case .recommended: loadRecommended()
        case .browse: loadBrowse()
        case .playlists: loadPlaylists()
        }
    }

    func loadRecommended() {
        guard let ref = currentLibrary, let base = baseURL, let token = serverToken else { return }
        tabLoading = true
        recommendedHubs = []
        Task {
            let hubs = (try? await api.hubs(base: base, token: token, sectionKey: ref.sectionKey)) ?? []
            recommendedHubs = hubs.filter { ($0.metadata?.isEmpty == false) }
            tabLoading = false
        }
    }

    func loadPlaylists() {
        guard let base = baseURL, let token = serverToken else { return }
        tabLoading = true
        Task {
            playlists = (try? await api.playlists(base: base, token: token)) ?? []
            tabLoading = false
        }
    }

    func loadBrowse() {
        guard let ref = currentLibrary, let base = baseURL, let token = serverToken else { return }
        let type: Int? = ref.type == "show" ? (tvEpisodes ? 4 : 2) : nil
        let sort = sortField.key + (sortAscending ? ":asc" : ":desc")
        let cacheKey = "\(ref.id)|type=\(type ?? -1)|sort=\(sort)"

        // Show cached items immediately (if any) while we refresh in the
        // background; otherwise show the connecting indicator.
        if let cached = PlexBrowseCache.shared.load(cacheKey), !cached.isEmpty {
            browseItems = cached
            libraryLoadState = .ready
        } else {
            browseItems = []
            libraryLoadState = .connecting
        }

        Task {
            do {
                let items = try await api.sectionItems(
                    base: base, token: token, sectionKey: ref.sectionKey,
                    type: type, sort: sort,
                    onResponse: { [weak self] in
                        Task { @MainActor in
                            if self?.libraryLoadState == .connecting { self?.libraryLoadState = .downloading }
                        }
                    }
                )
                browseItems = items
                libraryLoadState = .ready
                PlexBrowseCache.shared.save(cacheKey, items: items)
            } catch {
                // Keep showing cached results if we have them; only surface the
                // error when there's nothing to display.
                if browseItems.isEmpty { libraryLoadState = .failed(classify(error)) }
            }
        }
    }

    func setSortField(_ field: PlexSortField) { sortField = field; loadBrowse() }
    func setSortAscending(_ ascending: Bool) { sortAscending = ascending; loadBrowse() }
    func setTVEpisodes(_ episodes: Bool) { tvEpisodes = episodes; loadBrowse() }

    // MARK: Drill-down

    func open(item: PlexMetadata) {
        if item.isPlaylist { openPlaylist(item); return }
        if item.isPlayable { playSingle(item); return }
        guard let base = baseURL, let token = serverToken else { return }
        Task {
            if let children = try? await api.children(base: base, token: token, ratingKey: item.ratingKey) {
                stack.append(BrowseLevel(title: item.title, items: children))
            }
        }
    }

    func openPlaylist(_ item: PlexMetadata) {
        guard let base = baseURL, let token = serverToken else { return }
        Task {
            if let items = try? await api.playlistItems(base: base, token: token, ratingKey: item.ratingKey) {
                stack.append(BrowseLevel(title: item.title, items: items))
            }
        }
    }

    func back() {
        if !stack.isEmpty { stack.removeLast() } else { selectHome() }
    }

    // MARK: Images

    func imageURL(for path: String?) -> URL? {
        guard let base = baseURL, let token = serverToken else { return nil }
        return api.imageURL(base: base, token: token, path: path)
    }

    // MARK: Playback

    func playSingle(_ item: PlexMetadata) {
        playQueue = [item]
        queueIndex = 0
        Task { await startPlayback(item, resumeAt: nil) }
    }

    func playAll(_ items: [PlexMetadata], shuffle: Bool) {
        var queue = items.filter { $0.isPlayable }
        guard !queue.isEmpty else { return }
        if shuffle { queue.shuffle() }
        playQueue = queue
        queueIndex = 0
        Task { await startPlayback(queue[0], resumeAt: nil) }
    }

    private func advanceQueue() {
        queueIndex += 1
        if queueIndex < playQueue.count {
            let next = playQueue[queueIndex]
            Task { await startPlayback(next, resumeAt: nil) }
        } else {
            closePlayer()
        }
    }

    private func startPlayback(_ requested: PlexMetadata, resumeAt: CMTime?) async {
        guard let base = baseURL, let token = serverToken else { return }
        // Ensure we know the real container/codecs before deciding direct-play
        // vs transcode; list metadata often omits them.
        var item = requested
        if item.partContainer == nil, let detailed = try? await api.metadata(base: base, token: token, ratingKey: item.ratingKey) {
            item = detailed
        }
        guard let url = api.playbackURL(base: base, token: token, item: item, quality: quality) else { return }
        let player = AVPlayer(url: url)
        if let resumeAt {
            player.seek(to: resumeAt)
        } else if let offsetMs = item.viewOffset, offsetMs > 0 {
            player.seek(to: CMTime(seconds: Double(offsetMs) / 1000.0, preferredTimescale: 600))
        }
        player.volume = Float(volume)
        player.isMuted = isMuted
        nowPlayingItem = item
        nowPlayingTitle = item.type == "episode"
            ? [item.grandparentTitle, item.title].compactMap { $0 }.joined(separator: " — ")
            : item.title
        observePlayback(player)
        observeEnd(of: player)
        withAnimation(.easeInOut(duration: 0.25)) {
            self.player = player
            isPlayerMinimized = false
        }
        player.play()
    }

    private func observePlayback(_ player: AVPlayer) {
        statusObservation?.invalidate()
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    private func observeEnd(of player: AVPlayer) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.advanceQueue() }
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    /// In-app volume, independent of the device's hardware volume.
    func setVolume(_ newValue: Double) {
        volume = max(0, min(1, newValue))
        player?.volume = Float(volume)
        if volume > 0 && isMuted {
            isMuted = false
            player?.isMuted = false
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    func minimizePlayer() { withAnimation(.easeInOut(duration: 0.25)) { isPlayerMinimized = true } }
    func expandPlayer() { withAnimation(.easeInOut(duration: 0.25)) { isPlayerMinimized = false } }

    func closePlayer() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        withAnimation(.easeInOut(duration: 0.25)) {
            player = nil
            isPlayerMinimized = false
        }
        nowPlayingTitle = nil
        nowPlayingItem = nil
        isPlaying = false
        playQueue = []
        queueIndex = 0
    }

    func setQuality(_ newQuality: PlexQuality) {
        guard newQuality != quality else { return }
        quality = newQuality
        guard let item = nowPlayingItem, let player else { return }
        let resume = player.currentTime()
        Task { await startPlayback(item, resumeAt: resume) }
    }

    func presentInfo() {
        guard let item = nowPlayingItem else { return }
        if let base = baseURL, let token = serverToken {
            Task {
                let detailed = (try? await api.metadata(base: base, token: token, ratingKey: item.ratingKey)) ?? item
                infoItem = detailed
            }
        } else {
            infoItem = item
        }
    }

    // MARK: Error classification

    private func classify(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost,
                 .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                return "No response from the server (couldn't connect)."
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Container view

struct PlexPlayerContainerView: View {
    @ObservedObject var model: PlexPlayerViewModel

    var body: some View {
        ZStack {
            Palette.windowBackground
            content
                .safeAreaInset(edge: .bottom) { miniBar }
        }
        .overlay { fullPlayer }
        .sheet(isPresented: $model.showLibraryPicker) { LibraryPickerView(model: model) }
        .sheet(item: $model.infoItem) { item in MediaInfoView(item: item) }
        .onAppear { model.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .signedOut:
            SignInView(model: model)
        case .linking(let code):
            LinkingView(model: model, code: code)
        case .loading(let message):
            VStack(spacing: 12) {
                ProgressView()
                Text(message).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            ErrorView(model: model, message: message)
        case .browsing:
            BrowseView(model: model)
        }
    }

    @ViewBuilder
    private var miniBar: some View {
        if model.player != nil && model.isPlayerMinimized {
            MiniPlayerBar(model: model).transition(.move(edge: .bottom))
        }
    }

    @ViewBuilder
    private var fullPlayer: some View {
        if model.player != nil && !model.isPlayerMinimized {
            FullPlayerView(model: model).transition(.opacity)
        }
    }
}

// MARK: - Sign-in / linking / error

private struct SignInView: View {
    @ObservedObject var model: PlexPlayerViewModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.circle.fill").font(.system(size: 56)).foregroundStyle(.orange)
            Text("Plex Player").font(.title2).bold()
            Text("Sign in to browse and play your Plex library natively.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            Button("Sign in to Plex") { model.beginLinking() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

private struct LinkingView: View {
    @ObservedObject var model: PlexPlayerViewModel
    let code: String
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Waiting for Plex sign-in…").font(.headline)
            Text("A browser window opened to link this app. If it didn't, go to plex.tv/link and enter this code:")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            Text(code.uppercased())
                .font(.system(.largeTitle, design: .monospaced)).bold().tracking(4).textSelection(.enabled)
            HStack {
                Button("Reopen link page") { model.reopenLinkPage() }
                Button("Cancel", role: .cancel) { model.cancelLinking() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

private struct ErrorView: View {
    @ObservedObject var model: PlexPlayerViewModel
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.yellow)
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 340)
            HStack {
                Button("Retry") { Task { await model.connect() } }.buttonStyle(.borderedProminent)
                Button("Sign out") { model.signOut() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

// MARK: - Browse

private struct BrowseView: View {
    @ObservedObject var model: PlexPlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let level = model.stack.last {
                DrillView(model: model, level: level)
            } else if case .library = model.mode {
                LibraryRootView(model: model)
            } else {
                ScrollView { HomeView(model: model) }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.showLibraryPicker = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.stack")
                    Text(model.navTitle).fontWeight(.semibold)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.borderless)
            .help("Choose library")

            if !model.stack.isEmpty {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                Button { model.back() } label: {
                    Label(model.stack.last?.title ?? "", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            Menu {
                Button("Reload") { model.loadLibraryTab() }
                Button("Sign out", role: .destructive) { model.signOut() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
    }
}

private struct HomeView: View {
    @ObservedObject var model: PlexPlayerViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !model.onDeck.isEmpty { HubRail(model: model, title: "On Deck", items: model.onDeck) }
            if !model.recentlyAdded.isEmpty { HubRail(model: model, title: "Recently Added", items: model.recentlyAdded) }
            if !model.sections.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Libraries").font(.title3).bold()
                    ForEach(model.sections) { section in
                        Button { model.openHomeSection(section) } label: {
                            Label(section.title, systemImage: section.symbolName).padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if model.onDeck.isEmpty && model.recentlyAdded.isEmpty && model.sections.isEmpty {
                Text("Nothing to show yet.").foregroundStyle(.secondary)
            }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Library root (tabbed)

private struct LibraryRootView: View {
    @ObservedObject var model: PlexPlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { model.libraryTab }, set: { model.setLibraryTab($0) })) {
                ForEach(PlexPlayerViewModel.LibraryTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            switch model.libraryTab {
            case .recommended: RecommendedTab(model: model)
            case .browse: BrowseTab(model: model)
            case .playlists: PlaylistsTab(model: model)
            }
        }
    }
}

private struct RecommendedTab: View {
    @ObservedObject var model: PlexPlayerViewModel
    var body: some View {
        if model.tabLoading && model.recommendedHubs.isEmpty {
            LoadingBanner(text: "Loading recommendations…")
        } else if model.recommendedHubs.isEmpty {
            EmptyBanner(text: "No recommendations for this library.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(model.recommendedHubs) { hub in
                        HubRail(model: model, title: hub.title ?? "", items: hub.metadata ?? [])
                    }
                }
                .padding()
            }
        }
    }
}

private struct BrowseTab: View {
    @ObservedObject var model: PlexPlayerViewModel
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            switch model.libraryLoadState {
            case .connecting:
                LoadingBanner(text: "Contacting server…")
            case .downloading:
                LoadingBanner(text: "Downloading library…")
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Retry") { model.loadBrowse() }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            case .idle, .ready:
                if model.browseItems.isEmpty {
                    EmptyBanner(text: "This library is empty.")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(model.browseItems) { item in
                                PosterCard(model: model, item: item) { model.open(item: item) }
                            }
                        }
                        .padding()
                    }
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Sort by", selection: Binding(get: { model.sortField }, set: { model.setSortField($0) })) {
                    ForEach(PlexSortField.allCases) { field in Text(field.rawValue).tag(field) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Order", selection: Binding(get: { model.sortAscending }, set: { model.setSortAscending($0) })) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                Label("\(model.sortField.rawValue) \(model.sortAscending ? "↑" : "↓")",
                      systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()

            if model.isShowLibrary {
                Picker("", selection: Binding(get: { model.tvEpisodes }, set: { model.setTVEpisodes($0) })) {
                    Text("Shows").tag(false)
                    Text("Episodes").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            Spacer()

            Button { model.playAll(model.browseItems, shuffle: false) } label: {
                Label("Play All", systemImage: "play.fill")
            }
            .disabled(!model.browseItems.contains { $0.isPlayable })
            Button { model.playAll(model.browseItems, shuffle: true) } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(!model.browseItems.contains { $0.isPlayable })
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct PlaylistsTab: View {
    @ObservedObject var model: PlexPlayerViewModel
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]
    var body: some View {
        if model.tabLoading && model.playlists.isEmpty {
            LoadingBanner(text: "Loading playlists…")
        } else if model.playlists.isEmpty {
            EmptyBanner(text: "No playlists on this server.")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.playlists) { playlist in
                        PosterCard(model: model, item: playlist, width: 150) { model.openPlaylist(playlist) }
                    }
                }
                .padding()
            }
        }
    }
}

private struct DrillView: View {
    @ObservedObject var model: PlexPlayerViewModel
    let level: PlexPlayerViewModel.BrowseLevel
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        ScrollView {
            if level.items.contains(where: { $0.isPlayable }) {
                HStack {
                    Button { model.playAll(level.items, shuffle: false) } label: {
                        Label("Play All", systemImage: "play.fill")
                    }
                    Button { model.playAll(level.items, shuffle: true) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding([.horizontal, .top])
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(level.items) { item in
                    PosterCard(model: model, item: item) { model.open(item: item) }
                }
            }
            .padding()
        }
    }
}

// MARK: - Reusable rows / cards / banners

private struct HubRail: View {
    @ObservedObject var model: PlexPlayerViewModel
    let title: String
    let items: [PlexMetadata]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        PosterCard(model: model, item: item, width: 130) { model.open(item: item) }
                    }
                }
            }
        }
    }
}

private struct PosterCard: View {
    @ObservedObject var model: PlexPlayerViewModel
    let item: PlexMetadata
    var width: CGFloat = 140
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Palette.selectedControl)
                    CachedAsyncImage(url: model.imageURL(for: item.posterPath)) {
                        Image(systemName: placeholderSymbol).font(.largeTitle).foregroundStyle(.secondary)
                    }
                    if item.isPlayable {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 30)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 3)
                    }
                }
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(item.title).font(.caption).bold().lineLimit(1).frame(width: width, alignment: .leading)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: width, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var placeholderSymbol: String {
        if item.isPlaylist { return "music.note.list" }
        return item.isPlayable ? "play.rectangle" : "square.stack"
    }
}

private struct LoadingBanner: View {
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

private struct EmptyBanner: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

// MARK: - Library picker sheet

private struct LibraryPickerView: View {
    @ObservedObject var model: PlexPlayerViewModel
    @ObservedObject private var prefs = PlexPreferences.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAll = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { model.selectHome() } label: { Label("Home", systemImage: "house") }
                }

                Section("Favorites") {
                    if prefs.favorites.isEmpty {
                        Text("No favorites yet. Tap the heart next to a library below.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(prefs.favorites) { ref in
                            LibraryRow(ref: ref, isFavorite: true,
                                       onSelect: { model.select(library: ref) },
                                       onToggleFavorite: { prefs.toggleFavorite(ref) })
                        }
                        .onMove { prefs.move(from: $0, to: $1) }
                    }
                }

                Section("All Libraries") {
                    Button {
                        withAnimation { showAll.toggle() }
                        if showAll { model.loadAllServerLibraries() }
                    } label: {
                        HStack {
                            Label("Browse all servers", systemImage: "square.stack.3d.up")
                            Spacer()
                            Image(systemName: showAll ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                // One Section per server so SwiftUI keeps each server's rows
                // distinctly identified (otherwise async loads get mismatched).
                if showAll {
                    ForEach(model.servers) { server in
                        Section {
                            let libs = model.serverLibraries[server.clientIdentifier] ?? []
                            if libs.isEmpty {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading…").foregroundStyle(.secondary)
                                }
                            } else {
                                ForEach(libs) { section in
                                    let ref = model.makeRef(server: server, section: section)
                                    LibraryRow(ref: ref, isFavorite: prefs.isFavorite(ref),
                                               onSelect: { model.select(library: ref) },
                                               onToggleFavorite: { prefs.toggleFavorite(ref) })
                                }
                            }
                        } header: {
                            Label(server.name, systemImage: "server.rack")
                        }
                    }
                }
            }
            .navigationTitle("Libraries")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                #else
                ToolbarItem { Button("Done") { dismiss() } }
                #endif
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }
}

private struct LibraryRow: View {
    let ref: PlexLibraryRef
    let isFavorite: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack {
            Button(action: onSelect) { Label(ref.title, systemImage: ref.symbolName) }
                .buttonStyle(.plain)
            Spacer()
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? Color.pink : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(isFavorite ? "Remove favorite" : "Add favorite")
        }
    }
}

// MARK: - Mini player

private struct MiniPlayerBar: View {
    @ObservedObject var model: PlexPlayerViewModel
    var body: some View {
        HStack(spacing: 12) {
            if let player = model.player {
                VideoPlayer(player: player)
                    .frame(width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.nowPlayingTitle ?? "Now Playing").font(.subheadline).lineLimit(1)
                Text(model.isPlaying ? "Playing" : "Paused").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.toggleMute() } label: {
                Image(systemName: model.isMuted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .help(model.isMuted ? "Unmute" : "Mute")
            Button { model.togglePlayPause() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            Button { model.expandPlayer() } label: { Image(systemName: "chevron.up").font(.title3) }
                .buttonStyle(.borderless).help("Expand")
            Button { model.closePlayer() } label: { Image(systemName: "xmark").font(.title3) }
                .buttonStyle(.borderless).help("Stop")
        }
        .padding(8).background(.bar).overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { model.expandPlayer() }
    }
}

// MARK: - Full player

private struct FullPlayerView: View {
    @ObservedObject var model: PlexPlayerViewModel
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let player = model.player { VideoPlayer(player: player).ignoresSafeArea() }
            controlBar
        }
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            Button { model.minimizePlayer() } label: { Image(systemName: "chevron.down").font(.title3) }
                .help("Minimize")
            Text(model.nowPlayingTitle ?? "").font(.headline).lineLimit(1)
            Spacer()

            // In-app volume (independent of the device volume) + mute.
            Button { model.toggleMute() } label: {
                Image(systemName: model.isMuted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.title3)
            }
            .help(model.isMuted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...1)
                .frame(width: 110)
                .tint(.white)

            Button { model.presentInfo() } label: { Image(systemName: "info.circle").font(.title3) }
                .help("Media info")
            Menu {
                Picker("Quality", selection: Binding(get: { model.quality }, set: { model.setQuality($0) })) {
                    ForEach(PlexQuality.allCases) { q in Text(q.rawValue).tag(q) }
                }
            } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
            }
            .menuIndicator(.hidden)
            .help("Playback quality")
            Button { model.closePlayer() } label: { Image(systemName: "xmark").font(.title3) }
                .help("Stop")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }
}

// MARK: - Media info sheet

private struct MediaInfoView: View {
    let item: PlexMetadata
    @Environment(\.dismiss) private var dismiss
    private var media: PlexMedia? { item.media?.first }

    var body: some View {
        NavigationStack {
            List {
                Section("Title") {
                    infoRow("Title", item.title)
                    if let subtitle = item.subtitle { infoRow("Details", subtitle) }
                    infoRow("Runtime", item.runtimeText)
                }
                Section("Video") {
                    infoRow("Resolution", resolutionText)
                    infoRow("Codec", media?.videoCodec?.uppercased())
                    infoRow("Frame rate", media?.videoFrameRate)
                    infoRow("Bitrate", media?.bitrate.map { "\($0) kbps" })
                }
                Section("Audio") {
                    infoRow("Codec", media?.audioCodec?.uppercased())
                    infoRow("Channels", media?.audioChannels.map(String.init))
                }
                Section("File") {
                    infoRow("Container", (media?.container ?? item.partContainer)?.uppercased())
                    infoRow("Size", fileSizeText)
                    infoRow("Filename", item.fileName)
                    if let path = item.filePath {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Path").font(.caption).foregroundStyle(.secondary)
                            Text(path).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Media Info")
            .toolbar { ToolbarItem { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private var resolutionText: String? {
        if let w = media?.width, let h = media?.height { return "\(w) × \(h)" }
        return media?.videoResolution?.uppercased()
    }

    private var fileSizeText: String? {
        guard let size = media?.parts?.first?.size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).multilineTextAlignment(.trailing)
            }
        }
    }
}
