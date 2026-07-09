import Foundation

enum PlexError: LocalizedError {
    case http(Int)
    case badResponse
    case noReachableConnection
    case notLinked

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Plex returned HTTP \(code)."
        case .badResponse: return "Unexpected response from Plex."
        case .noReachableConnection: return "Couldn't reach the Plex server."
        case .notLinked: return "Not signed in to Plex."
        }
    }
}

/// A thin async client for the Plex.tv account API and Plex Media Server.
/// Stateless apart from a stable client identifier; auth/server tokens are
/// passed in per call by the view model.
final class PlexAPI {
    let clientID: String
    let product = "ContainerPlus"
    let version = "1.0"

    #if os(macOS)
    let platform = "macOS"
    let device = "ContainerPlus (Mac)"
    #else
    let platform = "iOS"
    let device = "ContainerPlus (iPad)"
    #endif

    init() {
        if let existing = KeychainHelper.get("plex.clientId") {
            clientID = existing
        } else {
            let generated = UUID().uuidString
            KeychainHelper.set(generated, for: "plex.clientId")
            clientID = generated
        }
    }

    // MARK: Requests

    private func headers(token: String?) -> [String: String] {
        var h = [
            "X-Plex-Client-Identifier": clientID,
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Platform": platform,
            "X-Plex-Device": device,
            "X-Plex-Device-Name": device,
            "Accept": "application/json",
        ]
        if let token { h["X-Plex-Token"] = token }
        return h
    }

    private func request(_ url: URL, method: String = "GET", token: String?,
                         body: Data? = nil, contentType: String? = nil,
                         timeout: TimeInterval = 15) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in headers(token: token) { req.setValue(v, forHTTPHeaderField: k) }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PlexError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw PlexError.http(http.statusCode) }
        return data
    }

    private func get<T: Decodable>(_ url: URL, token: String?, timeout: TimeInterval = 15) async throws -> T {
        let data = try await request(url, token: token, timeout: timeout)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Authentication (PIN linking)

    /// Requests a short (4-character) PIN. We deliberately avoid `strong=true`:
    /// strong PINs are long and only work through the deep-link auth URL, not
    /// manual entry at plex.tv/link.
    func createPin() async throws -> PlexPin {
        let url = URL(string: "https://plex.tv/api/v2/pins")!
        let data = try await request(url, method: "POST", token: nil,
                                     body: "strong=false".data(using: .utf8),
                                     contentType: "application/x-www-form-urlencoded")
        return try JSONDecoder().decode(PlexPin.self, from: data)
    }

    func checkPin(id: Int) async throws -> PlexPin {
        let url = URL(string: "https://plex.tv/api/v2/pins/\(id)")!
        return try await get(url, token: nil)
    }

    /// The page the user visits to authorize this app by entering the PIN.
    /// (The `app.plex.tv/auth` deep link now redirects to the Plex web app, so
    /// we use the plain link page and rely on the 4-character code.)
    let linkPageURL = URL(string: "https://plex.tv/link")!

    // MARK: Server discovery

    func resources(token: String) async throws -> [PlexResource] {
        let url = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!
        return try await get(url, token: token)
    }

    /// Probe every connection concurrently and return the best-ranked one that
    /// answers (local preferred, then remote, then relay). Probing in parallel
    /// avoids waiting out a timeout on a dead address before trying the next.
    func reachableBaseURL(for server: PlexResource) async -> (base: URL, token: String)? {
        guard let token = server.accessToken, let connections = server.connections else { return nil }
        let ordered = connections.sorted { rank($0) < rank($1) }
        let best: (rank: Int, base: URL)? = await withTaskGroup(of: (Int, URL)?.self) { group in
            for (index, connection) in ordered.enumerated() {
                guard let base = URL(string: connection.uri) else { continue }
                group.addTask { [self] in await probe(base: base, token: token) ? (index, base) : nil }
            }
            var chosen: (Int, URL)?
            for await result in group {
                if let result, chosen == nil || result.0 < chosen!.0 { chosen = result }
            }
            return chosen
        }
        if let best { return (best.base, token) }
        return nil
    }

    private func rank(_ c: PlexConnection) -> Int {
        if c.relay == true { return 2 }
        return c.local ? 0 : 1
    }

    /// Quick reachability check against a base URL.
    func probe(base: URL, token: String, timeout: TimeInterval = 4) async -> Bool {
        guard let url = URL(string: base.absoluteString + "/identity") else { return false }
        do {
            _ = try await request(url, token: token, timeout: timeout)
            return true
        } catch {
            return false
        }
    }

    // MARK: Library

    func sections(base: URL, token: String) async throws -> [PlexDirectory] {
        let url = URL(string: base.absoluteString + "/library/sections")!
        let response: MediaContainerResponse = try await get(url, token: token)
        return response.mediaContainer.directory ?? []
    }

    func onDeck(base: URL, token: String) async throws -> [PlexMetadata] {
        try await metadataList(path: "/library/onDeck", base: base, token: token)
    }

    func recentlyAdded(base: URL, token: String) async throws -> [PlexMetadata] {
        try await metadataList(path: "/library/recentlyAdded", base: base, token: token)
    }

    /// All items in a section, optionally filtered by `type` (1 = movie,
    /// 2 = show, 4 = episode) and sorted (e.g. "addedAt:desc"). Uses a
    /// progress-aware fetch that won't time out on large libraries and reports
    /// when the server starts responding.
    func sectionItems(base: URL, token: String, sectionKey: String,
                      type: Int?, sort: String?,
                      onResponse: @escaping () -> Void = {}) async throws -> [PlexMetadata] {
        var params: [String] = []
        if let type { params.append("type=\(type)") }
        if let sort, !sort.isEmpty { params.append("sort=\(sort)") }
        let path = "/library/sections/\(sectionKey)/all"
            + (params.isEmpty ? "" : "?" + params.joined(separator: "&"))
        return try await fetchMetadataList(path: path, base: base, token: token, onResponse: onResponse)
    }

    func children(base: URL, token: String, ratingKey: String) async throws -> [PlexMetadata] {
        try await metadataList(path: "/library/metadata/\(ratingKey)/children", base: base, token: token)
    }

    func hubs(base: URL, token: String, sectionKey: String) async throws -> [PlexHub] {
        let url = URL(string: base.absoluteString + "/hubs/sections/\(sectionKey)?count=20")!
        let response: MediaContainerResponse = try await get(url, token: token)
        return response.mediaContainer.hub ?? []
    }

    func playlists(base: URL, token: String) async throws -> [PlexMetadata] {
        let url = URL(string: base.absoluteString + "/playlists")!
        let response: MediaContainerResponse = try await get(url, token: token)
        return response.mediaContainer.metadata ?? []
    }

    func playlistItems(base: URL, token: String, ratingKey: String) async throws -> [PlexMetadata] {
        try await fetchMetadataList(path: "/playlists/\(ratingKey)/items", base: base, token: token)
    }

    /// Fetch a metadata list with a generous timeout and a hook that fires the
    /// moment response headers arrive (so callers can distinguish "still
    /// waiting to connect" from "downloading the body").
    func fetchMetadataList(path: String, base: URL, token: String,
                           timeout: TimeInterval = 120,
                           onResponse: @escaping () -> Void = {}) async throws -> [PlexMetadata] {
        let url = URL(string: base.absoluteString + path)!
        var req = URLRequest(url: url, timeoutInterval: timeout)
        for (k, v) in headers(token: token) { req.setValue(v, forHTTPHeaderField: k) }
        let observer = PlexResponseObserver(onResponse: onResponse)
        let (data, resp) = try await URLSession.shared.data(for: req, delegate: observer)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PlexError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(MediaContainerResponse.self, from: data).mediaContainer.metadata ?? []
    }

    /// Full metadata for one item (includes Media/Part technical fields + file path).
    func metadata(base: URL, token: String, ratingKey: String) async throws -> PlexMetadata? {
        try await metadataList(path: "/library/metadata/\(ratingKey)", base: base, token: token).first
    }

    private func metadataList(path: String, base: URL, token: String) async throws -> [PlexMetadata] {
        let url = URL(string: base.absoluteString + path)!
        let response: MediaContainerResponse = try await get(url, token: token)
        return response.mediaContainer.metadata ?? []
    }

    // MARK: Media URLs

    func imageURL(base: URL, token: String, path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: base.absoluteString + path + "?X-Plex-Token=" + token)
    }

    /// A URL AVPlayer can play at the requested quality. `.original` direct-plays
    /// only files AVFoundation can natively handle (mp4/mov/m4v with H.264/HEVC
    /// video and AAC/MP3 audio); anything else — e.g. AVI or MKV — is sent to
    /// the Plex universal transcoder (HLS). Other qualities always transcode.
    func playbackURL(base: URL, token: String, item: PlexMetadata, quality: PlexQuality) -> URL? {
        if quality == .original, let partKey = item.partKey, canDirectPlay(item) {
            return URL(string: base.absoluteString + partKey + "?X-Plex-Token=" + token)
        }
        return transcodeURL(base: base, token: token, item: item, quality: quality)
    }

    /// Whether AVFoundation can most likely play the file as-is.
    func canDirectPlay(_ item: PlexMetadata) -> Bool {
        guard let container = item.partContainer?.lowercased(),
              ["mp4", "mov", "m4v"].contains(container) else { return false }
        let video = item.media?.first?.videoCodec?.lowercased()
        let audio = item.media?.first?.audioCodec?.lowercased()
        let okVideo = video.map { ["h264", "hevc", "h265", "mpeg4"].contains($0) } ?? false
        let okAudio = audio.map { ["aac", "mp3", "alac"].contains($0) } ?? true
        return okVideo && okAudio
    }

    func transcodeURL(base: URL, token: String, item: PlexMetadata, quality: PlexQuality) -> URL? {
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        // A per-playback session id is required by the universal transcoder.
        let session = UUID().uuidString
        var params = [
            "path=" + enc("/library/metadata/\(item.ratingKey)"),
            "mediaIndex=0",
            "partIndex=0",
            "protocol=hls",
            "fastSeek=1",
            "directPlay=0",
            "directStream=1",
            "subtitles=auto",
            "videoQuality=100",
            "session=" + enc(session),
            "X-Plex-Session-Identifier=" + enc(session),
            "X-Plex-Client-Identifier=" + enc(clientID),
            "X-Plex-Product=" + enc(product),
            "X-Plex-Platform=" + enc(platform),
            "X-Plex-Token=" + enc(token),
        ]
        if let bitrate = quality.maxVideoBitrateKbps {
            params.append("maxVideoBitrate=\(bitrate)")
        }
        if let resolution = quality.videoResolution {
            params.append("videoResolution=" + resolution)
        }
        return URL(string: base.absoluteString + "/video/:/transcode/universal/start.m3u8?"
                   + params.joined(separator: "&"))
    }
}

/// Selectable playback quality for the Plex player.
enum PlexQuality: String, CaseIterable, Identifiable {
    case original = "Original"
    case p1080 = "1080p (20 Mbps)"
    case p720 = "720p (4 Mbps)"
    case p480 = "480p (2 Mbps)"

    var id: String { rawValue }

    var maxVideoBitrateKbps: Int? {
        switch self {
        case .original: return nil
        case .p1080: return 20000
        case .p720: return 4000
        case .p480: return 2000
        }
    }

    var videoResolution: String? {
        switch self {
        case .original: return nil
        case .p1080: return "1920x1080"
        case .p720: return "1280x720"
        case .p480: return "720x480"
        }
    }
}

/// Sortable fields for the Browse tab.
enum PlexSortField: String, CaseIterable, Identifiable {
    case name = "Name"
    case releaseDate = "Release Date"
    case dateAdded = "Date Added"

    var id: String { rawValue }

    var key: String {
        switch self {
        case .name: return "titleSort"
        case .releaseDate: return "originallyAvailableAt"
        case .dateAdded: return "addedAt"
        }
    }
}

/// Per-task delegate that reports when the server's response headers arrive,
/// letting callers tell "no response yet" apart from "downloading".
final class PlexResponseObserver: NSObject, URLSessionDataDelegate {
    private let onResponse: () -> Void
    private var fired = false

    init(onResponse: @escaping () -> Void) { self.onResponse = onResponse }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if !fired { fired = true; onResponse() }
        completionHandler(.allow)
    }
}
