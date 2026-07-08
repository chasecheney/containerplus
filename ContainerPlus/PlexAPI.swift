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

    /// The page the user visits to authorize this app.
    func authURL(code: String) -> URL {
        let forwardURL = "https://app.plex.tv/desktop"
        var items: [String] = []
        func add(_ key: String, _ value: String) {
            let v = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
            items.append("\(key)=\(v)")
        }
        add("clientID", clientID)
        add("code", code)
        add("context[device][product]", product)
        add("forwardUrl", forwardURL)
        var comps = URLComponents(string: "https://app.plex.tv/auth")!
        comps.fragment = "?" + items.joined(separator: "&")
        return comps.url!
    }

    // MARK: Server discovery

    func resources(token: String) async throws -> [PlexResource] {
        let url = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!
        return try await get(url, token: token)
    }

    /// Try each connection (local first, then remote, then relay) and return
    /// the first that answers, along with the server's access token.
    func reachableBaseURL(for server: PlexResource) async -> (base: URL, token: String)? {
        guard let token = server.accessToken, let connections = server.connections else { return nil }
        let ordered = connections.sorted { rank($0) < rank($1) }
        for connection in ordered {
            guard let base = URL(string: connection.uri) else { continue }
            if await ping(base: base, token: token) { return (base, token) }
        }
        return nil
    }

    private func rank(_ c: PlexConnection) -> Int {
        if c.relay == true { return 2 }
        return c.local ? 0 : 1
    }

    private func ping(base: URL, token: String) async -> Bool {
        guard let url = URL(string: base.absoluteString + "/identity") else { return false }
        do {
            _ = try await request(url, token: token, timeout: 5)
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

    func sectionItems(base: URL, token: String, sectionKey: String) async throws -> [PlexMetadata] {
        try await metadataList(path: "/library/sections/\(sectionKey)/all", base: base, token: token)
    }

    func children(base: URL, token: String, ratingKey: String) async throws -> [PlexMetadata] {
        try await metadataList(path: "/library/metadata/\(ratingKey)/children", base: base, token: token)
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

    /// A URL AVPlayer can play. Uses direct play for AVFoundation-friendly
    /// containers, otherwise the Plex universal transcoder (HLS).
    func playbackURL(base: URL, token: String, item: PlexMetadata) -> URL? {
        let friendly: Set<String> = ["mp4", "mov", "m4v"]
        if let partKey = item.partKey,
           let container = item.partContainer?.lowercased(),
           friendly.contains(container) {
            return URL(string: base.absoluteString + partKey + "?X-Plex-Token=" + token)
        }
        return transcodeURL(base: base, token: token, item: item)
    }

    func transcodeURL(base: URL, token: String, item: PlexMetadata) -> URL? {
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        let params = [
            "path=" + enc("/library/metadata/\(item.ratingKey)"),
            "mediaIndex=0",
            "partIndex=0",
            "protocol=hls",
            "fastSeek=1",
            "directPlay=0",
            "directStream=1",
            "subtitles=burn",
            "videoQuality=100",
            "maxVideoBitrate=20000",
            "X-Plex-Client-Identifier=" + enc(clientID),
            "X-Plex-Product=" + enc(product),
            "X-Plex-Platform=" + enc(platform),
            "X-Plex-Token=" + enc(token),
        ]
        return URL(string: base.absoluteString + "/video/:/transcode/universal/start.m3u8?"
                   + params.joined(separator: "&"))
    }
}
