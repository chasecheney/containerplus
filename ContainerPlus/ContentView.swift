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

/// Chrome around a pane. The container content fills the whole pane; there is
/// no visible picker. To switch containers, **right-click (macOS)** or
/// **long-press (iPadOS)** anywhere in the pane — including over web content —
/// and choose from the menu.
struct ContainerHostView: View {
    @ObservedObject var pane: PaneModel
    @State private var showMenu = false

    var body: some View {
        ZStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Click-through recognizer; fires the menu even over a WKWebView.
            SecondaryActivationView { showMenu = true }
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .confirmationDialog("Choose container", isPresented: $showMenu, titleVisibility: .visible) {
            ForEach(ContainerType.allCases) { type in
                Button {
                    pane.selection = type
                } label: {
                    Text(pane.selection == type ? "\(type.rawValue) ✓" : type.rawValue)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
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
