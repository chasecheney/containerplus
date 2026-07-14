import Foundation
import CryptoKit

/// A persistent full-text index for a bundle's story bodies.
///
/// Built once (by decompressing and tokenizing every story — the expensive
/// part, done off the main thread with progress) and cached to disk
/// (LZFSE-compressed), so later sessions load it instead of rebuilding. Query
/// is prefix-matched per term and AND-combined across terms, so it stays fast
/// even at 20k+ stories.
struct StoryFullText: Codable {
    /// ordinal → story stem
    let stems: [String]
    /// sorted vocabulary
    let words: [String]
    /// posting lists parallel to `words` (sorted story ordinals)
    let postings: [[Int32]]

    // MARK: Tokenizing

    static func tokenize(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    // MARK: Query

    /// Stems matching all query terms (each term prefix-matched). Returns nil
    /// when the query has no usable (≥2-char) terms.
    func matches(_ query: String) -> Set<String>? {
        let terms = Array(Set(Self.tokenize(query)))
        guard !terms.isEmpty else { return nil }

        var acc: Set<Int32>?
        for term in terms {
            let ords = ordinals(prefix: term)
            acc = acc.map { $0.intersection(ords) } ?? ords
            if acc?.isEmpty == true { return [] }
        }
        guard let ords = acc else { return nil }
        var out = Set<String>()
        out.reserveCapacity(ords.count)
        for o in ords where Int(o) < stems.count { out.insert(stems[Int(o)]) }
        return out
    }

    private func ordinals(prefix: String) -> Set<Int32> {
        var out = Set<Int32>()
        var i = lowerBound(prefix)
        while i < words.count, words[i].hasPrefix(prefix) {
            out.formUnion(postings[i])
            i += 1
        }
        return out
    }

    private func lowerBound(_ p: String) -> Int {
        var lo = 0, hi = words.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if words[mid] < p { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: Build

    /// Decompresses every story and builds the index. `entries` order fixes the
    /// ordinal↔stem mapping. Throws on cancellation or read failure.
    static func build(url: URL, entries: [StoryBundle.ManifestEntry], blobStart: UInt64,
                      progress: @escaping (Int, Int) -> Void) throws -> StoryFullText {
        let stems = entries.map { $0.stem }
        var vocab: [String: Set<Int32>] = [:]
        let total = entries.count

        for (ordinal, entry) in entries.enumerated() {
            try Task.checkCancellation()
            if let body = try? StoryBundle.readBody(at: url, entry: entry, blobStart: blobStart) {
                for word in Set(tokenize(body)) {
                    vocab[word, default: []].insert(Int32(ordinal))
                }
            }
            if (ordinal + 1) % 200 == 0 || ordinal + 1 == total { progress(ordinal + 1, total) }
        }

        let words = vocab.keys.sorted()
        let postings = words.map { vocab[$0]!.sorted() }
        return StoryFullText(stems: stems, words: words, postings: postings)
    }

    // MARK: Disk cache (LZFSE-compressed JSON)

    private static var cacheDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("StoryFullText", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFile(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(hash + ".ftidx")
    }

    static func loadCache(key: String) -> StoryFullText? {
        guard let packed = try? Data(contentsOf: cacheFile(key)),
              let json = try? (packed as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(StoryFullText.self, from: json)
    }

    static func saveCache(key: String, index: StoryFullText) {
        guard let json = try? JSONEncoder().encode(index),
              let packed = try? (json as NSData).compressed(using: .lzfse) as Data else { return }
        try? packed.write(to: cacheFile(key), options: .atomic)
    }
}
