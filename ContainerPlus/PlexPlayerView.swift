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

    /// A level in the browse stack (a library section or a drilled-in show/season).
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
    @Published private(set) var stack: [BrowseLevel] = []
    @Published private(set) var currentLibraryTitle: String = "Home"

    /// Libraries per server for the picker's "All Libraries" view.
    @Published private(set) var serverLibraries: [String: [PlexDirectory]] = [:]

    // Player
    @Published var player: AVPlayer?
    @Published private(set) var nowPlayingTitle: String?
    @Published private(set) var nowPlayingItem: PlexMetadata?
    @Published var isPlayerMinimized = false
    @Published private(set) var isPlaying = false
    @Published private(set) var quality: PlexQuality = .original

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

    /// Non-isolated so a pane (created off the main actor) can construct it;
    /// all stored properties have default values.
    nonisolated init() {}

    private var authToken: String? {
        get { KeychainHelper.get("plex.authToken") }
        set {
            if let newValue { KeychainHelper.set(newValue, for: "plex.authToken") }
            else { KeychainHelper.delete("plex.authToken") }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard case .signedOut = phase else { return }
        if authToken != nil {
            Task { await connect() }
        }
    }

    // MARK: Sign in / out

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
        baseURL = nil
        serverToken = nil
        connectionCache = [:]
        servers = []
        selectedServer = nil
        sections = []
        onDeck = []
        recentlyAdded = []
        serverLibraries = [:]
        stack = []
        currentLibraryTitle = "Home"
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

    // MARK: Connect + servers

    func connect() async {
        guard let token = authToken else { phase = .signedOut; return }
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
            phase = .error(error.localizedDescription)
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
        currentLibraryTitle = "Home"
        await loadHome()
    }

    func loadHome() async {
        guard let base = baseURL, let token = serverToken else { return }
        phase = .loading("Loading your library…")
        stack = []
        currentLibraryTitle = "Home"
        async let deck = try? api.onDeck(base: base, token: token)
        async let recent = try? api.recentlyAdded(base: base, token: token)
        async let secs = try? api.sections(base: base, token: token)
        onDeck = await deck ?? []
        recentlyAdded = await recent ?? []
        sections = await secs ?? []
        phase = .browsing
    }

    /// Load every server's library list for the picker's "All Libraries" view.
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

    // MARK: Library / Home selection

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
            currentLibraryTitle = ref.title
            let items = (try? await api.sectionItems(base: conn.base, token: conn.token, sectionKey: ref.sectionKey)) ?? []
            stack = [BrowseLevel(title: ref.title, items: items)]
            phase = .browsing
        }
    }

    func openHomeSection(_ section: PlexDirectory) {
        guard let server = selectedServer else { return }
        select(library: makeRef(server: server, section: section))
    }

    // MARK: Browsing / drill-down

    func open(item: PlexMetadata) {
        if item.isPlayable { play(item: item); return }
        guard let base = baseURL, let token = serverToken else { return }
        Task {
            if let children = try? await api.children(base: base, token: token, ratingKey: item.ratingKey) {
                stack.append(BrowseLevel(title: item.title, items: children))
            }
        }
    }

    /// Back within the current library; from the library root, returns Home.
    func back() {
        if stack.count > 1 { stack.removeLast() } else { selectHome() }
    }

    // MARK: Images

    func imageURL(for path: String?) -> URL? {
        guard let base = baseURL, let token = serverToken else { return nil }
        return api.imageURL(base: base, token: token, path: path)
    }

    // MARK: Playback

    func play(item: PlexMetadata, resumeAt: CMTime? = nil) {
        guard let base = baseURL, let token = serverToken,
              let url = api.playbackURL(base: base, token: token, item: item, quality: quality) else { return }
        let player = AVPlayer(url: url)
        if let resumeAt {
            player.seek(to: resumeAt)
        } else if let offsetMs = item.viewOffset, offsetMs > 0 {
            player.seek(to: CMTime(seconds: Double(offsetMs) / 1000.0, preferredTimescale: 600))
        }
        nowPlayingItem = item
        nowPlayingTitle = item.type == "episode"
            ? [item.grandparentTitle, item.title].compactMap { $0 }.joined(separator: " — ")
            : item.title
        observePlayback(player)
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

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    func minimizePlayer() {
        withAnimation(.easeInOut(duration: 0.25)) { isPlayerMinimized = true }
    }

    func expandPlayer() {
        withAnimation(.easeInOut(duration: 0.25)) { isPlayerMinimized = false }
    }

    func closePlayer() {
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        withAnimation(.easeInOut(duration: 0.25)) {
            player = nil
            isPlayerMinimized = false
        }
        nowPlayingTitle = nil
        nowPlayingItem = nil
        isPlaying = false
    }

    func setQuality(_ newQuality: PlexQuality) {
        guard newQuality != quality else { return }
        quality = newQuality
        guard let item = nowPlayingItem, let player else { return }
        play(item: item, resumeAt: player.currentTime())
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
        .sheet(isPresented: $model.showLibraryPicker) {
            LibraryPickerView(model: model)
        }
        .sheet(item: $model.infoItem) { item in
            MediaInfoView(item: item)
        }
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
            MiniPlayerBar(model: model)
                .transition(.move(edge: .bottom))
        }
    }

    @ViewBuilder
    private var fullPlayer: some View {
        if model.player != nil && !model.isPlayerMinimized {
            FullPlayerView(model: model)
                .transition(.opacity)
        }
    }
}

// MARK: - Sign-in / linking / error

private struct SignInView: View {
    @ObservedObject var model: PlexPlayerViewModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 56)).foregroundStyle(.orange)
            Text("Plex Player").font(.title2).bold()
            Text("Sign in to browse and play your Plex library natively.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Sign in to Plex") { model.beginLinking() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Text(code.uppercased())
                .font(.system(.largeTitle, design: .monospaced)).bold()
                .tracking(4)
                .textSelection(.enabled)
            HStack {
                Button("Reopen link page") { model.reopenLinkPage() }
                Button("Cancel", role: .cancel) { model.cancelLinking() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct ErrorView: View {
    @ObservedObject var model: PlexPlayerViewModel
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundStyle(.yellow)
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 340)
            HStack {
                Button("Retry") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent)
                Button("Sign out") { model.signOut() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Browse

private struct BrowseView: View {
    @ObservedObject var model: PlexPlayerViewModel
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                if let level = model.stack.last {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(level.items) { item in
                            PosterCard(model: model, item: item) { model.open(item: item) }
                        }
                    }
                    .padding()
                } else {
                    home
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            // Top-left library dropdown.
            Button {
                model.showLibraryPicker = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.stack")
                    Text(model.currentLibraryTitle).fontWeight(.semibold)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.borderless)
            .help("Choose library")

            if model.stack.count > 1 {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                Button { model.back() } label: {
                    Label(model.stack.last?.title ?? "", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            Menu {
                Button("Reload") { Task { await model.loadHome() } }
                Button("Sign out", role: .destructive) { model.signOut() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var home: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !model.onDeck.isEmpty {
                HubRow(model: model, title: "On Deck", items: model.onDeck)
            }
            if !model.recentlyAdded.isEmpty {
                HubRow(model: model, title: "Recently Added", items: model.recentlyAdded)
            }
            if !model.sections.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Libraries").font(.title3).bold()
                    ForEach(model.sections) { section in
                        Button {
                            model.openHomeSection(section)
                        } label: {
                            Label(section.title, systemImage: section.symbolName)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if model.onDeck.isEmpty && model.recentlyAdded.isEmpty && model.sections.isEmpty {
                Text("Nothing to show yet.").foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HubRow: View {
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
                    AsyncImage(url: model.imageURL(for: item.thumb)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: item.isPlayable ? "play.rectangle" : "square.stack")
                            .font(.largeTitle).foregroundStyle(.secondary)
                    }
                    if item.isPlayable {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 3)
                    }
                }
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(item.title).font(.caption).bold().lineLimit(1)
                    .frame(width: width, alignment: .leading)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: width, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
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
                    Button {
                        model.selectHome()
                    } label: {
                        Label("Home", systemImage: "house")
                    }
                }

                Section("Favorites") {
                    if prefs.favorites.isEmpty {
                        Text("No favorites yet. Tap the heart next to a library in All Libraries.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(prefs.favorites) { ref in
                            LibraryRow(ref: ref,
                                       isFavorite: true,
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
                            Image(systemName: showAll ? "chevron.down" : "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    if showAll {
                        ForEach(model.servers) { server in
                            let libs = model.serverLibraries[server.clientIdentifier] ?? []
                            HStack(spacing: 6) {
                                Image(systemName: "server.rack").foregroundStyle(.secondary)
                                Text(server.name).font(.subheadline).bold()
                            }
                            if libs.isEmpty {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading…").foregroundStyle(.secondary)
                                }
                            } else {
                                ForEach(libs) { section in
                                    let ref = model.makeRef(server: server, section: section)
                                    LibraryRow(ref: ref,
                                               isFavorite: prefs.isFavorite(ref),
                                               onSelect: { model.select(library: ref) },
                                               onToggleFavorite: { prefs.toggleFavorite(ref) })
                                }
                            }
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
            Button(action: onSelect) {
                Label(ref.title, systemImage: ref.symbolName)
            }
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
            Button { model.togglePlayPause() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            Button { model.expandPlayer() } label: {
                Image(systemName: "chevron.up").font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Expand")
            Button { model.closePlayer() } label: {
                Image(systemName: "xmark").font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Stop")
        }
        .padding(8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
            if let player = model.player {
                VideoPlayer(player: player).ignoresSafeArea()
            }
            controlBar
        }
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            Button { model.minimizePlayer() } label: {
                Image(systemName: "chevron.down").font(.title3)
            }
            .help("Minimize")

            Text(model.nowPlayingTitle ?? "")
                .font(.headline).lineLimit(1)

            Spacer()

            Button { model.presentInfo() } label: {
                Image(systemName: "info.circle").font(.title3)
            }
            .help("Media info")

            Menu {
                Picker("Quality", selection: Binding(
                    get: { model.quality },
                    set: { model.setQuality($0) }
                )) {
                    ForEach(PlexQuality.allCases) { q in Text(q.rawValue).tag(q) }
                }
            } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
            }
            .menuIndicator(.hidden)
            .help("Playback quality")

            Button { model.closePlayer() } label: {
                Image(systemName: "xmark").font(.title3)
            }
            .help("Stop")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LinearGradient(colors: [.black.opacity(0.65), .clear],
                           startPoint: .top, endPoint: .bottom)
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
