import Foundation
#if os(macOS)
import AppKit
#endif

/// Imports bookmarks from other browsers. Because the app is sandboxed, the
/// user picks the bookmarks file through an open panel (which grants read
/// access to that file). Both Safari's `Bookmarks.plist` and Chromium-family
/// `Bookmarks` JSON files are supported, auto-detected by content.
enum BookmarkImporter {

    enum Source: String, CaseIterable, Identifiable {
        case safari = "Safari"
        case chrome = "Chrome"
        case edge = "Edge"
        case brave = "Brave"
        case other = "Other…"

        var id: String { rawValue }

#if os(macOS)
        /// A best-effort default location to point the open panel at.
        /// (macOS only — the iPad importer uses the system file browser.)
        var suggestedDirectory: URL? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .safari: return home.appendingPathComponent("Library/Safari")
            case .chrome: return home.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
            case .edge:   return home.appendingPathComponent("Library/Application Support/Microsoft Edge/Default")
            case .brave:  return home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Default")
            case .other:  return home
            }
        }

        var suggestedFileName: String? {
            switch self {
            case .safari: return "Bookmarks.plist"
            case .chrome, .edge, .brave: return "Bookmarks"
            case .other: return nil
            }
        }
#endif
    }

#if os(macOS)
    /// macOS: present an open panel for the given source and return parsed
    /// bookmarks. (On iPadOS the caller uses SwiftUI's `.fileImporter` instead.)
    @MainActor
    static func promptImport(from source: Source) -> [Bookmark] {
        let panel = NSOpenPanel()
        panel.title = "Import Bookmarks from \(source.rawValue)"
        panel.message = "Select the bookmarks file to import."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let dir = source.suggestedDirectory { panel.directoryURL = dir }
        if let name = source.suggestedFileName { panel.nameFieldStringValue = name }

        guard panel.runModal() == .OK, let url = panel.url else { return [] }
        return parse(fileAt: url)
    }
#endif

    /// Parse a bookmarks file, auto-detecting Safari (plist), Chromium (JSON)
    /// or a Netscape-format HTML export. Handles security-scoped URLs so it
    /// works with files chosen through `.fileImporter` on iPadOS.
    static func parse(fileAt url: URL) -> [Bookmark] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parse(data: data)
    }

    static func parse(data: Data) -> [Bookmark] {
        // Property list → Safari.
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dict = plist as? [String: Any] {
            var out: [Bookmark] = []
            parseSafari(node: dict, into: &out)
            if !out.isEmpty { return out }
        }

        // JSON → Chromium family.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var out: [Bookmark] = []
            if let roots = json["roots"] as? [String: Any] {
                for (_, value) in roots {
                    if let node = value as? [String: Any] { parseChromium(node: node, into: &out) }
                }
            }
            if !out.isEmpty { return out }
        }

        // Netscape bookmark HTML export (File > Export Bookmarks in most browsers).
        var out: [Bookmark] = []
        parseHTML(data, into: &out)
        return out
    }

    private static func parseHTML(_ data: Data, into out: inout [Bookmark]) {
        guard let html = String(data: data, encoding: .utf8) else { return }
        let pattern = "<A[^>]*HREF=\"([^\"]+)\"[^>]*>(.*?)</A>"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let url = ns.substring(with: match.range(at: 1))
            var title = ns.substring(with: match.range(at: 2))
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Bookmark(title: title.isEmpty ? url : title, url: url))
        }
    }

    // MARK: Safari (Bookmarks.plist)

    private static func parseSafari(node: [String: Any], into out: inout [Bookmark]) {
        let type = node["WebBookmarkType"] as? String
        if type == "WebBookmarkTypeLeaf",
           let urlString = node["URLString"] as? String {
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                ?? node["Title"] as? String
                ?? urlString
            out.append(Bookmark(title: title, url: urlString))
        }
        if let children = node["Children"] as? [[String: Any]] {
            for child in children { parseSafari(node: child, into: &out) }
        }
    }

    // MARK: Chromium (Bookmarks JSON)

    private static func parseChromium(node: [String: Any], into out: inout [Bookmark]) {
        if let type = node["type"] as? String {
            if type == "url", let url = node["url"] as? String {
                let name = node["name"] as? String ?? url
                out.append(Bookmark(title: name, url: url))
            } else if type == "folder", let children = node["children"] as? [[String: Any]] {
                for child in children { parseChromium(node: child, into: &out) }
            }
        } else if let children = node["children"] as? [[String: Any]] {
            for child in children { parseChromium(node: child, into: &out) }
        }
    }
}
