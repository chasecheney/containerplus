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

/// Backing state for a single pane. Each pane keeps its own long-lived
/// container instances so that switching the picker (or resizing the split)
/// never throws away browser tabs or the Plex session.
final class PaneModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var selection: ContainerType

    /// Long-lived so the tab set survives container switches.
    let browser: BrowserViewModel
    /// Long-lived so Plex cookies / playback survive container switches.
    let plex: PlexViewModel
    /// Long-lived so the Plex session / browse state survives container switches.
    let plexPlayer: PlexPlayerViewModel

    init(selection: ContainerType, homeURL: URL? = nil) {
        self.selection = selection
        self.browser = BrowserViewModel()
        self.plex = PlexViewModel()
        self.plexPlayer = PlexPlayerViewModel()
        if let homeURL { self.browser.newTab(url: homeURL, select: true) }
        else { self.browser.newTab(url: URL(string: "https://www.google.com")!, select: true) }
    }
}
