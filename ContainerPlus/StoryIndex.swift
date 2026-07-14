import Foundation
import CryptoKit

/// Builds (and caches) the parsed, grouped, sorted index for a bundle. All of
/// this is CPU-heavy for large libraries (regex-parsing tens of thousands of
/// filenames), so it always runs off the main thread, and the result is cached
/// to disk keyed by the bundle's identity so re-opening is instant.
enum StoryIndex {

    struct Built {
        var storiesByStem: [String: StoryItem]
        var entriesByStem: [String: StoryBundle.ManifestEntry]
        var series: [StorySeries]        // sorted by sortKey
        var allTags: [String]
        var blobStart: UInt64
    }

    // MARK: Natural-sort key

    /// Lowercased title with digit runs zero-padded to 8, so lexicographic
    /// order matches natural order ("Part 2" < "Part 10") without ICU cost.
    static func naturalKey(_ title: String) -> String {
        var out = ""
        out.reserveCapacity(title.count + 8)
        var digits = ""
        for ch in title.lowercased() {
            if ch.isNumber {
                digits.append(ch)
            } else {
                if !digits.isEmpty {
                    out += String(repeating: "0", count: max(0, 8 - digits.count)) + digits
                    digits = ""
                }
                out.append(ch)
            }
        }
        if !digits.isEmpty {
            out += String(repeating: "0", count: max(0, 8 - digits.count)) + digits
        }
        return out
    }

    // MARK: Build

    /// Reads the manifest and parses/groups it (or loads a cached parse).
    /// Nonisolated + throwing so it can run from a detached task.
    static func open(url: URL) throws -> Built {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let cacheKey = "\(url.path)|\(size)|\(mtime)"

        if let cached = loadCache(key: cacheKey) {
            return reconstruct(from: cached)
        }

        let (manifest, blobStart) = try StoryBundle.readManifest(at: url)
        let built = build(entries: manifest.entries, blobStart: blobStart)
        saveCache(key: cacheKey, built: built)
        return built
    }

    private static func build(entries: [StoryBundle.ManifestEntry], blobStart: UInt64) -> Built {
        var storiesByStem: [String: StoryItem] = [:]
        var entriesByStem: [String: StoryBundle.ManifestEntry] = [:]
        var byKey: [String: [StoryItem]] = [:]
        var tagSet = Set<String>()
        storiesByStem.reserveCapacity(entries.count)
        entriesByStem.reserveCapacity(entries.count)

        for entry in entries {
            entriesByStem[entry.stem] = entry
            let parsed = StoryFilenameParser.parse(stem: entry.stem)
            let seriesKey = StoryFilenameParser.baseTitle(parsed.title).lowercased()
            let searchKey = (parsed.title + " " + parsed.tags.joined(separator: " ")).lowercased()
            let item = StoryItem(id: parsed.storyID ?? entry.stem,
                                 stem: entry.stem,
                                 title: parsed.title,
                                 seriesKey: seriesKey,
                                 tags: parsed.tags,
                                 size: Int(entry.size),
                                 searchKey: searchKey)
            storiesByStem[entry.stem] = item
            parsed.tags.forEach { tagSet.insert($0) }
            byKey[seriesKey, default: []].append(item)
        }

        let series = groupedSeries(byKey)
        return Built(storiesByStem: storiesByStem, entriesByStem: entriesByStem,
                     series: series, allTags: tagSet.sorted(), blobStart: blobStart)
    }

    private static func groupedSeries(_ byKey: [String: [StoryItem]]) -> [StorySeries] {
        var series: [StorySeries] = []
        series.reserveCapacity(byKey.count)
        for (key, items) in byKey {
            let sorted = items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let title = StoryFilenameParser.baseTitle(sorted[0].title)
            series.append(StorySeries(id: key, title: title, sortKey: naturalKey(title), stories: sorted))
        }
        series.sort { $0.sortKey < $1.sortKey }
        return series
    }

    // MARK: Disk cache (parsed index)

    private struct Cache: Codable {
        struct Item: Codable {
            let stem: String, id: String, title: String, seriesKey: String, searchKey: String
            let tags: [String]
            let offset: UInt64, size: UInt64, mtime: Double
        }
        var blobStart: UInt64
        var items: [Item]
    }

    private static var cacheDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("StoryBundleIndex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFile(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(hash + ".json")
    }

    private static func loadCache(key: String) -> Cache? {
        guard let data = try? Data(contentsOf: cacheFile(key)) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private static func saveCache(key: String, built: Built) {
        let items = built.storiesByStem.values.map { item -> Cache.Item in
            let e = built.entriesByStem[item.stem]
            return Cache.Item(stem: item.stem, id: item.id, title: item.title,
                              seriesKey: item.seriesKey, searchKey: item.searchKey,
                              tags: item.tags, offset: e?.offset ?? 0, size: e?.size ?? UInt64(item.size),
                              mtime: e?.mtime ?? 0)
        }
        let cache = Cache(blobStart: built.blobStart, items: items)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheFile(key), options: .atomic)
        }
    }

    private static func reconstruct(from cache: Cache) -> Built {
        var storiesByStem: [String: StoryItem] = [:]
        var entriesByStem: [String: StoryBundle.ManifestEntry] = [:]
        var byKey: [String: [StoryItem]] = [:]
        var tagSet = Set<String>()
        storiesByStem.reserveCapacity(cache.items.count)
        entriesByStem.reserveCapacity(cache.items.count)

        for it in cache.items {
            entriesByStem[it.stem] = StoryBundle.ManifestEntry(stem: it.stem, offset: it.offset, size: it.size, mtime: it.mtime)
            let item = StoryItem(id: it.id, stem: it.stem, title: it.title, seriesKey: it.seriesKey,
                                 tags: it.tags, size: Int(it.size), searchKey: it.searchKey)
            storiesByStem[it.stem] = item
            it.tags.forEach { tagSet.insert($0) }
            byKey[it.seriesKey, default: []].append(item)
        }
        return Built(storiesByStem: storiesByStem, entriesByStem: entriesByStem,
                     series: groupedSeries(byKey), allTags: tagSet.sorted(), blobStart: cache.blobStart)
    }
}
