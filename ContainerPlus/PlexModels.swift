import Foundation

// MARK: - plex.tv account API (v2)

/// A linking PIN from `POST https://plex.tv/api/v2/pins`.
struct PlexPin: Decodable {
    let id: Int
    let code: String
    let authToken: String?
}

/// A device/resource from `GET https://plex.tv/api/v2/resources`.
struct PlexResource: Decodable, Identifiable {
    let name: String
    let clientIdentifier: String
    let provides: String
    let accessToken: String?
    let connections: [PlexConnection]?

    var id: String { clientIdentifier }
    var isServer: Bool { provides.contains("server") }
}

struct PlexConnection: Decodable {
    let uri: String
    let local: Bool
    let relay: Bool?
    let address: String?
    let port: Int?
    let `protocol`: String?
}

// MARK: - Plex Media Server responses (MediaContainer)

struct MediaContainerResponse: Decodable {
    let mediaContainer: MediaContainer
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
}

struct MediaContainer: Decodable {
    let directory: [PlexDirectory]?
    let metadata: [PlexMetadata]?
    enum CodingKeys: String, CodingKey {
        case directory = "Directory"
        case metadata = "Metadata"
    }
}

/// A library section (e.g. "Movies", "TV Shows").
struct PlexDirectory: Decodable, Identifiable {
    let key: String
    let title: String
    let type: String?
    var id: String { key }

    var symbolName: String {
        switch type {
        case "movie": return "film"
        case "show": return "tv"
        case "artist": return "music.note"
        case "photo": return "photo"
        default: return "square.stack"
        }
    }
}

/// A media item: movie, show, season, or episode.
struct PlexMetadata: Decodable, Identifiable {
    let ratingKey: String
    let key: String
    let type: String
    let title: String
    let grandparentTitle: String?
    let parentTitle: String?
    let summary: String?
    let thumb: String?
    let art: String?
    let year: Int?
    let index: Int?
    let duration: Int?
    let viewOffset: Int?
    let media: [PlexMedia]?

    var id: String { ratingKey }

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, title, grandparentTitle, parentTitle
        case summary, thumb, art, year, index, duration, viewOffset
        case media = "Media"
    }

    /// The first playable file part key, if this item can be played directly.
    var partKey: String? { media?.first?.parts?.first?.key }
    var partContainer: String? { media?.first?.parts?.first?.container }

    /// Items with a file part (movies, episodes) are playable; shows/seasons
    /// must be drilled into first.
    var isPlayable: Bool { partKey != nil }

    /// A display subtitle, e.g. "Show Name · S1 · E3".
    var subtitle: String? {
        switch type {
        case "episode":
            var parts: [String] = []
            if let show = grandparentTitle { parts.append(show) }
            if let e = index { parts.append("Episode \(e)") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "movie":
            return year.map(String.init)
        default:
            return type.capitalized
        }
    }
}

extension PlexMetadata {
    /// The on-disk filename of the first part, if known.
    var fileName: String? {
        guard let path = media?.first?.parts?.first?.file else { return nil }
        return (path as NSString).lastPathComponent
    }

    var filePath: String? { media?.first?.parts?.first?.file }

    /// Human-readable runtime, e.g. "1h 42m".
    var runtimeText: String? {
        guard let ms = duration ?? media?.first?.duration, ms > 0 else { return nil }
        let totalMinutes = ms / 60000
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

struct PlexMedia: Decodable {
    let parts: [PlexPart]?
    let videoResolution: String?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let videoCodec: String?
    let audioCodec: String?
    let videoFrameRate: String?
    let audioChannels: Int?
    let container: String?
    let duration: Int?

    enum CodingKeys: String, CodingKey {
        case parts = "Part"
        case videoResolution, bitrate, width, height
        case videoCodec, audioCodec, videoFrameRate, audioChannels, container, duration
    }
}

struct PlexPart: Decodable {
    let key: String?
    let container: String?
    let file: String?
    let size: Int?
}

/// A stable reference to a library section on a specific server, used for
/// favorites and cross-server browsing.
struct PlexLibraryRef: Codable, Identifiable, Hashable {
    let serverID: String
    let serverName: String
    let sectionKey: String
    let title: String
    let type: String?

    var id: String { serverID + ":" + sectionKey }

    var symbolName: String {
        switch type {
        case "movie": return "film"
        case "show": return "tv"
        case "artist": return "music.note"
        case "photo": return "photo"
        default: return "square.stack"
        }
    }
}
