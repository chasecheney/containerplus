import Foundation

/// Read-only reader for Story Reader's ".storybundle" library files.
///
/// File layout (little-endian):
///   bytes 0..<8    magic "STRYBNDL"
///   bytes 8..<12   format version (UInt32) — 1
///   bytes 12..<20  manifest JSON length (UInt64)
///   manifest JSON  (UTF-8)
///   blob region    LZFSE-compressed story texts, back to back
///
/// Each blob is byte-identical to the source library's on-disk ".lzfse" file
/// (starts with "bvx"), so we just seek + read + decompress on demand. User
/// metadata is intentionally not in the bundle — content only.
enum StoryBundle {

    static let magic = Data("STRYBNDL".utf8)
    static let formatVersion: UInt32 = 1

    struct ManifestEntry: Decodable {
        var stem: String
        var offset: UInt64
        var size: UInt64
        var mtime: Double
    }

    /// Only the fields the reader needs; other keys (userDictionary, tagRules,
    /// created, …) are ignored.
    struct Manifest: Decodable {
        var entries: [ManifestEntry]
        var storyCount: Int?
        var generator: String?
    }

    enum BundleError: LocalizedError {
        case notABundle
        case unsupportedVersion(UInt32)
        case corrupt(String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notABundle: return "This file is not a Story Reader library bundle."
            case .unsupportedVersion(let v): return "This bundle uses format version \(v), which this app can't read."
            case .corrupt(let d): return "The bundle appears to be damaged (\(d))."
            case .unreadable: return "Could not read a story from the bundle."
            }
        }
    }

    /// Reads and validates the header + manifest (fast — no blobs touched).
    static func readManifest(at url: URL) throws -> (manifest: Manifest, blobStart: UInt64) {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        guard let head = try fh.read(upToCount: 20), head.count == 20,
              head.prefix(8) == magic else { throw BundleError.notABundle }

        let version = head.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard version == formatVersion else { throw BundleError.unsupportedVersion(version) }

        let mlen = head.subdata(in: 12..<20).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        guard mlen > 0, mlen < 500_000_000 else { throw BundleError.corrupt("bad manifest length") }

        guard let mdata = try fh.read(upToCount: Int(mlen)), mdata.count == Int(mlen) else {
            throw BundleError.corrupt("truncated manifest")
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: mdata) else {
            throw BundleError.corrupt("unreadable manifest")
        }
        return (manifest, 20 + mlen)
    }

    /// Reads and decompresses one story's text from the bundle.
    static func readBody(at url: URL, entry: ManifestEntry, blobStart: UInt64) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: blobStart + entry.offset)
        guard let blob = try fh.read(upToCount: Int(entry.size)), blob.count == Int(entry.size) else {
            throw BundleError.corrupt("truncated blob")
        }
        let data = try (blob as NSData).decompressed(using: .lzfse) as Data
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        throw BundleError.unreadable
    }
}
