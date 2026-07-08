# ContainerPlus

A **multiplatform** app (macOS + iPadOS) that shows two **containers** side by
side. The divider between them is draggable and **snaps at 25%, 50% and 75%**
of the width.

Panes have no visible chrome — the container fills the whole pane. To switch a
pane's container, **right-click (macOS)** or **long-press (iPadOS)** anywhere in
it (this works even over web content) and pick from the menu. Three containers
are built in:

## Plex Web
A locked web view for [app.plex.tv](https://app.plex.tv). There is no address
bar. Cookies and local storage are persisted (shared `WKWebsiteDataStore`), so
you stay signed in across launches. The last Plex URL is also cached in the
keychain. **Long-press** anywhere in the Plex view (or right-click →
*Refresh to Plex Home*) to return to the home page.

## Web Browser
A tabbed browser built on `WKWebView`:
- Tabs with title, loading state and close buttons; **+** opens a new tab.
- Address bar that navigates URLs or falls back to a Google search.
- Back / forward / reload / stop.
- **New windows open as new tabs** (`window.open`, `target="_blank"`,
  ⌘-click), and background tabs keep loading.
- **Bookmark import** from Safari, Chrome, Edge, Brave, or any file. Because
  the app is sandboxed, you pick the bookmarks file in an open panel; Safari
  `Bookmarks.plist`, Chromium `Bookmarks` JSON, and Netscape HTML exports are
  auto-detected. On iPad you pick the file via the system file importer; on Mac
  via an open panel that can point at each browser's bookmarks folder.

## Plex Player
A **native** Plex client (no web view) built on the Plex API and `AVPlayer`:
- **Sign in** with Plex's PIN linking flow — the app opens plex.tv in your
  browser and shows the code; the auth token is stored in the keychain.
- **Server discovery** via `plex.tv/api/v2/resources`, testing each connection
  (local → remote → relay) and using the first that responds.
- **Browse** On Deck, Recently Added, and your libraries, drilling into shows →
  seasons → episodes.
- **Play** in an `AVPlayer` overlay, resuming from the last watched offset.
  Direct play is used for AVFoundation-friendly containers (mp4/mov/m4v);
  everything else falls back to the Plex universal transcoder (HLS).

Networking lives in `PlexAPI.swift` / `PlexModels.swift`; UI + state in
`PlexPlayerView.swift`. On iPad, reaching a server on your LAN triggers the
system local-network permission prompt (declared via
`NSLocalNetworkUsageDescription`).

> Note: the transcode URL uses sensible default parameters; depending on your
> server and media you may want to tune bitrate/quality in `PlexAPI.transcodeURL`.

## Build & run
1. Open `ContainerPlus.xcodeproj` in Xcode 16 or later.
2. Pick a run destination:
   - **My Mac** (macOS 14+), or
   - an **iPad** simulator / device (iPadOS 17+).
3. In *Signing & Capabilities*, pick your team (automatic signing) — or, on Mac,
   "Sign to Run Locally".
4. Run (⌘R).

The single app target is multiplatform (`SUPPORTED_PLATFORMS = iphoneos
iphonesimulator macosx`, device family iPhone/iPad). Platform-specific bits
(the `WKWebView` wrapper, colors, resize cursor, window chrome, and bookmark
file picking) are handled with `#if os(macOS)` / `os(iOS)`. The App Sandbox
entitlements apply on macOS only (`CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`).

## Project layout
The Xcode project uses a **file-system-synchronized group**, so every file in
`ContainerPlus/` is compiled automatically — no need to edit the project when
adding files.

| File | Role |
| --- | --- |
| `ContainerPlusApp.swift` | App entry point |
| `ContentView.swift` | Two panes + per-pane container picker |
| `SplitContainerView.swift` | Resizable, snapping split |
| `ContainerType.swift` | Container enum + `PaneModel` |
| `PlexWebView.swift` | Locked Plex web view |
| `PlexPlayerView.swift` | Native Plex player UI + view model |
| `PlexAPI.swift` / `PlexModels.swift` | Plex API client + Codable models |
| `BrowserView.swift` | Tabbed browser UI |
| `BrowserTab.swift` / `BrowserViewModel.swift` | Browser state |
| `BookmarkImporter.swift` | Safari / Chromium bookmark import |
| `WebViewRepresentable.swift` | Shared `WKWebView` wrapper |
| `KeychainHelper.swift` | Small keychain wrapper |

## Adding more containers
Add a case to `ContainerType`, then render it in `ContainerHostView.content`.
