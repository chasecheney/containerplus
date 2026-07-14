import SwiftUI

/// One story (one part), derived from a bundle manifest entry.
struct StoryItem: Identifiable, Hashable {
    /// Stable identity: the numeric id from the filename, else the stem.
    let id: String
    let stem: String
    let title: String
    let seriesKey: String
    let tags: [String]
    let size: Int
    /// Precomputed lowercased "title + tags" so search never re-lowercases at
    /// scale.
    let searchKey: String

    static func == (lhs: StoryItem, rhs: StoryItem) -> Bool { lhs.stem == rhs.stem }
    func hash(into hasher: inout Hasher) { hasher.combine(stem) }
}

/// Related parts grouped under one series title.
struct StorySeries: Identifiable, Hashable {
    let id: String            // lowercased series key
    let title: String
    /// Precomputed natural-sort key (digit runs zero-padded) so ordering is a
    /// plain `String <` — far cheaper than `localizedStandardCompare` at scale.
    let sortKey: String
    var stories: [StoryItem]  // natural-sorted by title
    var tags: [String] { Array(Set(stories.flatMap { $0.tags })).sorted() }
}

/// Reading themes (ported from Story Reader).
enum ReaderTheme: String, CaseIterable, Identifiable {
    case system, light, sepia, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var background: Color? {
        switch self {
        case .system: return nil
        case .light: return Color.white
        case .sepia: return Color(red: 0.96, green: 0.93, blue: 0.86)
        case .dark: return Color(red: 0.11, green: 0.11, blue: 0.12)
        }
    }
    var foreground: Color? {
        switch self {
        case .system: return nil
        case .light: return Color.black
        case .sepia: return Color(red: 0.24, green: 0.20, blue: 0.14)
        case .dark: return Color(red: 0.86, green: 0.86, blue: 0.87)
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .sepia: return .light
        case .dark: return .dark
        }
    }
}

/// Local, per-story reading state (the bundle carries no metadata, and the
/// reader is read-only). Persisted in UserDefaults keyed by story id.
struct StoryReadingState: Codable {
    var position: Double = 0     // 0…1
    var favorite: Bool = false
    var read: Bool = false
}
