import SwiftUI

struct ContentView: View {
    // The two panes default to Plex Web (left) and Web Browser (right),
    // matching the required first two containers.
    @StateObject private var left = PaneModel(selection: .plexWeb)
    @StateObject private var right = PaneModel(selection: .webBrowser)

    var body: some View {
        SplitContainerView {
            ContainerHostView(pane: left)
        } right: {
            ContainerHostView(pane: right)
        }
        .background(Palette.windowBackground)
    }
}

/// Chrome around a pane. The container content fills the whole pane. A small
/// floating menu button in the bottom-trailing corner switches the container.
/// It's a real control layered above the content, so it works reliably even
/// over a `WKWebView` (unlike a gesture, which the web view would swallow).
struct ContainerHostView: View {
    @ObservedObject var pane: PaneModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            FloatingContainerMenu(pane: pane)
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var content: some View {
        switch pane.selection {
        case .plexWeb:
            PlexContainerView(model: pane.plex)
        case .webBrowser:
            BrowserContainerView(model: pane.browser)
        case .plexPlayer:
            PlexPlayerContainerView(model: pane.plexPlayer)
        }
    }
}

/// Small always-available button that opens a menu to pick the container
/// (and container-specific actions, e.g. Plex "go home").
private struct FloatingContainerMenu: View {
    @ObservedObject var pane: PaneModel
    @State private var hovering = false

    var body: some View {
        Menu {
            Picker("Container", selection: $pane.selection) {
                ForEach(ContainerType.allCases) { type in
                    Label(type.rawValue, systemImage: type.symbolName).tag(type)
                }
            }
            .pickerStyle(.inline)

            if pane.selection == .plexWeb {
                Divider()
                Button {
                    pane.plex.goHome()
                } label: {
                    Label("Refresh to Plex Home", systemImage: "house")
                }
            }
        } label: {
            Image(systemName: pane.selection.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Palette.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(hovering ? 1.0 : 0.7)
        .help("Switch container")
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
    }
}
