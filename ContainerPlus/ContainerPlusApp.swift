import SwiftUI

@main
struct ContainerPlusApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
            #if os(macOS)
                .frame(minWidth: 900, minHeight: 560)
            #endif
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1400, height: 860)
        .commands {
            // Remove the default "New Window" clutter; the app is a single split workspace.
            CommandGroup(replacing: .newItem) {}
        }
        #endif
    }
}
