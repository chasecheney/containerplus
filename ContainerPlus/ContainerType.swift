import SwiftUI

/// The kinds of content that can be shown inside a pane.
/// The first two required containers are Plex Web and Web Browser.
enum ContainerType: String, CaseIterable, Identifiable {
    case plexWeb = "Plex Web"
    case webBrowser = "Web Browser"
    case plexPlayer = "Plex Player"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .plexWeb: return "play.rectangle.fill"
        case .webBrowser: return "globe"
        case .plexPlayer: return "play.circle.fill"
        }
    }
}

/// Backing state for a single pane. Container instances are created **lazily**
/// on first use, so a pane doesn't spin up a WKWebView / Plex session it never
/// shows. Once created they're long-lived, so switching the picker (or resizing
/// the split) never throws away browser tabs or the Plex session.
final class PaneModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var selection: ContainerType

    /// Created on first access; the browser opens its home tab in its own init.
    lazy var browser = BrowserViewModel()
    lazy var plex = PlexViewModel()
    lazy var plexPlayer = PlexPlayerViewModel()

    init(selection: ContainerType) {
        self.selection = selection
    }
}
