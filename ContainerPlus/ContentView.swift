import SwiftUI

struct ContentView: View {
    private static let leftKey = "containerplus.leftContainer"
    private static let rightKey = "containerplus.rightContainer"

    @StateObject private var left: PaneModel
    @StateObject private var right: PaneModel

    init() {
        // Restore each pane's last-selected container (defaults: Plex API + Web).
        let defaults = UserDefaults.standard
        let l = ContainerType(rawValue: defaults.string(forKey: Self.leftKey) ?? "") ?? .plexPlayer
        let r = ContainerType(rawValue: defaults.string(forKey: Self.rightKey) ?? "") ?? .webBrowser
        _left = StateObject(wrappedValue: PaneModel(selection: l))
        _right = StateObject(wrappedValue: PaneModel(selection: r))
    }

    var body: some View {
        SplitContainerView {
            ContainerHostView(pane: left)
        } right: {
            ContainerHostView(pane: right)
        }
        .background(Palette.windowBackground)
        .onChange(of: left.selection) { _, value in
            UserDefaults.standard.set(value.rawValue, forKey: Self.leftKey)
        }
        .onChange(of: right.selection) { _, value in
            UserDefaults.standard.set(value.rawValue, forKey: Self.rightKey)
        }
    }
}

/// Width reserved at the top-right of a pane's own toolbar for the container
/// picker, so it doesn't overlap the container's controls.
let containerPickerReservedWidth: CGFloat = 46

/// Chrome around a pane. The container content fills the whole pane. A small
/// floating menu button switches the container — top-right for most containers,
/// but bottom-right for Plex Web (whose own site UI lives in the top-right).
/// It's a real control layered above the content, so it works reliably even
/// over a `WKWebView` (unlike a gesture, which the web view would swallow).
struct ContainerHostView: View {
    @ObservedObject var pane: PaneModel

    private var pickerAlignment: Alignment {
        pane.selection == .plexWeb ? .bottomTrailing : .topTrailing
    }

    var body: some View {
        ZStack(alignment: pickerAlignment) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            FloatingContainerMenu(pane: pane)
                .padding(.horizontal, 10)
                .padding(pane.selection == .plexWeb ? .bottom : .top, 8)
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
        case .storyReader:
            StoryReaderContainerView(model: pane.storyReader)
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
