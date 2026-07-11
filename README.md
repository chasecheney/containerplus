# ContainerPlus

A **multiplatform** app (macOS + iPadOS) that shows two **containers** side by
side. The divider between them is draggable and **snaps at 25%, 50% and 75%**
of the width.

The container fills the whole pane. A small **floating menu button** switches
the container (and offers "Refresh to Plex Home" when Plex Web is showing).
It's a real control layered above the content, so it works reliably even over
web views. Four containers are built in:

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
- Back / forward / reload / stop / **Home**.
- **Bookmarks**: the star toggles a bookmark for the current page (filled when
  bookmarked). The book menu opens recent bookmarks and offers "Manage
  Bookmarks…" (a searchable editor to open/rename/edit/delete individually) and
  "Clear All Bookmarks". Bookmarks and the home page are shared across panes and
  persist across launches.
- **Home page**: set it from the book menu ("Set current page as Home" or
  "Change home page…"); new tabs and the Home button open it.
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
- **Library switcher**: a dropdown in the top-left opens a picker with your
  **favorite libraries** (reorderable, heart to favorite/unfavorite) and a
  "Browse all servers" section listing every server and its libraries.
- **Library tabs**: each library has **Recommended** (Plex hubs), **Browse**,
  and **Playlists** (server-side). Browse sorts by Name / Release Date / Date
  Added, ascending or descending; TV libraries toggle **Shows vs Episodes**;
  and **Play All / Shuffle All** queues the current list. Large libraries show
  a distinct "Contacting server…" vs "Downloading library…" state (and won't
  time out), so a stalled connection is distinguishable from a slow download.
- **Minimizable player**: the collapse (⌄) button shrinks playback into a
  bottom mini-bar (with play/pause, expand, stop) so you can keep browsing
  while the video keeps playing; tap the bar to expand again.
- **Playback quality**: switch between Original and 1080p/720p/480p transcodes
  (resumes at the current position).
- **Audio & subtitles**: the gear button lists the stream's audio tracks and
  subtitle tracks (including Off), read from the player's media selection groups.
- **Queue**: long-press a poster for "Play Next" / "Add to Queue"; the hamburger
  button shows the up-next list (tap to jump, swipe to remove).
- **Media info**: the ℹ️ button shows resolution, codecs, bitrate, container,
  size, and the file's name/path — and, if enabled in Settings, a
  **Delete from Plex** action (confirmed; requires the server to allow deletion).
- **Settings** (… menu): preferred default streaming rate, show/hide the
  network debug overlay, and opt in to the delete action. All persisted.
- **Play** in an `AVPlayer`, resuming from the last watched offset. Direct play
  is used for AVFoundation-friendly containers (mp4/mov/m4v); everything else
  falls back to the Plex universal transcoder (HLS).

Networking lives in `PlexAPI.swift` / `PlexModels.swift`; UI + state in
`PlexPlayerView.swift`. On iPad, reaching a server on your LAN triggers the
system local-network permission prompt (declared via
`NSLocalNetworkUsageDescription`).

## Story Reader
A **read-only** reader for Story Reader / Story Navigator `.storybundle`
library files (a compressed, single-file bundle: header + manifest + LZFSE
story blobs). Open a bundle and it lists stories grouped into series (shared
`FilenameParser` logic), filterable by **tag** and searchable by title/tag —
tags are for navigation only, with no editing, tagging, or spell-check. The
reader has adjustable text size, serif/sans, light/sepia/dark themes,
previous/next-part navigation, favorites, read status, and resume position
(all stored locally; the bundle carries content, not reading state). Stories
are decompressed on demand straight from the bundle. Code: `StoryBundle.swift`,
`StoryFilenameParser.swift`, `StoryModels.swift`, `StoryReaderView.swift`.

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
