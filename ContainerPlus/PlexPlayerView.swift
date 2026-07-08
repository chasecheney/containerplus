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
    @Published private(set) var sections: [PlexDirectory] = []
    @Published private(set) var onDeck: [PlexMetadata] = []
    @Published private(set) var recentlyAdded: [PlexMetadata] = []
    @Published private(set) var stack: [BrowseLevel] = []
    @Published private(set) var nowPlayingTitle: String?
    @Published var player: AVPlayer?

    let api = PlexAPI()
    private var baseURL: URL?
    private var serverToken: String?
    private var pollTask: Task<Void, Never>?

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
                SystemBrowser.open(api.authURL(code: pin.code))
                try await pollForToken(pinID: pin.id)
            } catch is CancellationError {
                // user cancelled
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    func reopenLinkPage() {
        if case .linking(let code) = phase {
            SystemBrowser.open(api.authURL(code: code))
        }
    }

    func cancelLinking() {
        pollTask?.cancel()
        phase = .signedOut
    }

    func signOut() {
        pollTask?.cancel()
        authToken = nil
        baseURL = nil
        serverToken = nil
        servers = []
        selectedServer = nil
        sections = []
        onDeck = []
        recentlyAdded = []
        stack = []
        closePlayer()
        phase = .signedOut
    }

    private func pollForToken(pinID: Int) async throws {
        // Poll up to ~5 minutes. Transient network errors are ignored so a
        // single hiccup doesn't abort the whole sign-in.
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

    // MARK: Connect + load

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

    func select(server: PlexResource) async {
        selectedServer = server
        phase = .loading("Connecting to \(server.name)…")
        guard let reachable = await api.reachableBaseURL(for: server) else {
            phase = .error("Couldn't reach \(server.name).")
            return
        }
        baseURL = reachable.base
        serverToken = reachable.token
        await loadHome()
    }

    func loadHome() async {
        guard let base = baseURL, let token = serverToken else { return }
        phase = .loading("Loading your library…")
        stack = []
        async let deck = try? api.onDeck(base: base, token: token)
        async let recent = try? api.recentlyAdded(base: base, token: token)
        async let secs = try? api.sections(base: base, token: token)
        onDeck = await deck ?? []
        recentlyAdded = await recent ?? []
        sections = await secs ?? []
        phase = .browsing
    }

    // MARK: Browsing

    func open(section: PlexDirectory) {
        guard let base = baseURL, let token = serverToken else { return }
        Task {
            do {
                let items = try await api.sectionItems(base: base, token: token, sectionKey: section.key)
                stack.append(BrowseLevel(title: section.title, items: items))
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    func open(item: PlexMetadata) {
        if item.isPlayable {
            play(item: item)
            return
        }
        guard let base = baseURL, let token = serverToken else { return }
        Task {
            do {
                let children = try await api.children(base: base, token: token, ratingKey: item.ratingKey)
                stack.append(BrowseLevel(title: item.title, items: children))
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    func popLevel() {
        if !stack.isEmpty { stack.removeLast() }
    }

    // MARK: Images / playback

    func imageURL(for path: String?) -> URL? {
        guard let base = baseURL, let token = serverToken else { return nil }
        return api.imageURL(base: base, token: token, path: path)
    }

    func play(item: PlexMetadata) {
        guard let base = baseURL, let token = serverToken,
              let url = api.playbackURL(base: base, token: token, item: item) else { return }
        let player = AVPlayer(url: url)
        // Resume from where the user left off, if Plex reported an offset.
        if let offsetMs = item.viewOffset, offsetMs > 0 {
            player.seek(to: CMTime(seconds: Double(offsetMs) / 1000.0, preferredTimescale: 600))
        }
        nowPlayingTitle = item.type == "episode"
            ? [item.grandparentTitle, item.title].compactMap { $0 }.joined(separator: " — ")
            : item.title
        self.player = player
        player.play()
    }

    func closePlayer() {
        player?.pause()
        player = nil
        nowPlayingTitle = nil
    }
}

// MARK: - Container view

struct PlexPlayerContainerView: View {
    @ObservedObject var model: PlexPlayerViewModel

    var body: some View {
        ZStack {
            Palette.windowBackground
            content
            if model.player != nil { playerOverlay }
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
        case .error(let message):
            ErrorView(model: model, message: message)
        case .browsing:
            BrowseView(model: model)
        }
    }

    private var playerOverlay: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player = model.player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    model.closePlayer()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(12)
                if let title = model.nowPlayingTitle {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                }
            }
        }
    }
}

// MARK: - Sub-views

private struct SignInView: View {
    @ObservedObject var model: PlexPlayerViewModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Plex Player")
                .font(.title2).bold()
            Text("Sign in to browse and play your Plex library natively.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Sign in to Plex") { model.beginLinking() }
                .buttonStyle(.borderedProminent)
        }
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
            Text(message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack {
                Button("Retry") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent)
                Button("Sign out") { model.signOut() }
            }
        }
        .padding()
    }
}

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
            if !model.stack.isEmpty {
                Button { model.popLevel() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
            }
            Text(model.stack.last?.title ?? "Home")
                .font(.headline)
            Spacer()
            if model.servers.count > 1 {
                Menu {
                    ForEach(model.servers) { server in
                        Button(server.name) { Task { await model.select(server: server) } }
                    }
                } label: {
                    Label(model.selectedServer?.name ?? "Server", systemImage: "server.rack")
                }
                .fixedSize()
            }
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
                            model.open(section: section)
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
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
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

                Text(item.title)
                    .font(.caption).bold()
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: width, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
