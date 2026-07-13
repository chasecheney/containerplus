# ContainerPlus 1.0.2

**A side-by-side "container" workspace for macOS and iPad.** ContainerPlus puts
two resizable panes on screen at once, and each pane can host any of four
containers — a native Plex client, a locked Plex Web view, a tabbed web
browser, or a read-only story reader. Adjust the split, snap it to common
ratios, and switch either pane's container from a floating menu. Your layout,
pane choices, and per-container state persist across launches.

- **Platforms:** macOS 14+ and iPadOS 17+ (single multiplatform build)
- **Download:** `ContainerPlus-1.0.2.dmg`
- **SHA-256:** `89e9642f8b88483dabe8d2c867de3110972bf045b8a685f122ef848e72ba489f`

---

## The workspace

- **Two panes, one window.** A draggable divider resizes the panes live via a
  smooth guide, with the actual content redrawn on release, and **snaps at 25% /
  50% / 75%**. The split fraction is remembered between launches.
- **Floating container picker.** Each pane has a small menu button (top-right for
  most containers, bottom-right for Plex Web so it doesn't cover that site's own
  controls) to switch what the pane shows. The selected container per pane is
  remembered.
- **Lazy + long-lived.** A container is created the first time you open it and
  then kept alive, so switching panes never throws away your browser tabs or
  Plex session — but panes you never open cost nothing at launch.

---

## Containers

### Plex Player — native Plex client
A no-web-view Plex client that talks to the Plex API directly and plays video in
`AVPlayer`. Also available as the standalone app **PlexPlus**:
👉 https://github.com/chasecheney/plexplus

- **Sign in** with Plex's PIN linking flow (token stored in the keychain), then
  **server discovery** that probes each address (local → remote → relay) and
  uses the first that responds, self-healing bad cached connections.
- **Browse** On Deck, Recently Added, and your libraries — drilling shows →
  seasons → episodes — with a **library switcher** (reorderable favorites and a
  "Browse all servers" section) and per-library tabs: **Recommended**, **Browse**
  (sortable by name / release date / date added / **duration**, Shows vs Episodes
  for TV), and **Playlists**. **Play All / Shuffle All** on any list.
- **Universal search** available everywhere: search a specific library, another
  server, or **all libraries at once**, with sort controls, instant re-query on
  scope/sort changes, matching **playlists** in results, Play All / Shuffle on
  results, and the ability to **save results to a playlist**.
- **Photos** route to an image viewer instead of the video player.
- **Player**: full-screen on iPad with tap-to-toggle controls, a custom scrubber
  (live seeking), **±15s double-tap**, pinch-to-zoom with drag-to-pan, a
  minimizable **mini-player** that keeps playing while you browse (including
  **background playback on iPad**), previous/next queue navigation, in-app
  volume, and **audio / subtitle track selection**.
- **Queue**: long-press a poster for **Play Next** / **Add to Queue**; a queue
  list windowed around the current item.
- **Quality & transcoding**: direct play for AVFoundation-friendly containers
  (mp4/mov/m4v), otherwise the Plex universal transcoder (HLS) with selectable
  Original / 1080p / 720p / 480p that resumes at the current position; transcode
  sessions are stopped when you're done, and watch progress is reported back to
  Plex (On Deck / resume / watched state).
- **Media info** (resolution, codecs, bitrate, container, size, file path) and an
  optional, confirmed **Delete from Plex**.
- **Diagnostics** for tricky servers: a network log, transcode probe, and an
  optional network-debug overlay — all opt-in in Settings.

### Story Reader — read-only story library
Opens a Story Reader **`.storybundle`** — the single-file, LZFSE-compressed
library exported by the Story Reader / Story Navigator app:
👉 https://github.com/chasecheney/reader

- Lists stories **grouped into series** using the same filename-parsing logic as
  the source app ("…, Part 1/2/3", chapters, roman numerals).
- **Tags for navigation** (filter by tag) plus title/tag search — **read-only**:
  no editing, tagging, or spell-check.
- A clean reader with adjustable text size, serif/sans, **light / sepia / dark**
  themes, previous/next-part navigation, favorites, read status, and **resume
  position** — all stored locally (the bundle carries content, not reading
  state). Stories are decompressed on demand straight from the bundle.

### Plex Web — locked web player
A dedicated, chrome-free web view pinned to **app.plex.tv** with persistent
authentication, plus a "Refresh to Plex Home" action in the pane's menu.

### Web Browser — tabbed browser
A `WKWebView`-based browser with tabs, an address bar (URL or search),
back/forward/reload/home, new-window-as-tab, a configurable **home page**, and a
persistent **bookmarks** manager (star to add, search/edit/delete, import from
Safari/Chrome/Firefox HTML exports).

---

## Notable since the initial release

- Universal, cross-library **search** with server/library scoping, sort controls,
  playlist matches, and **save-to-playlist**.
- **Duration** added as a sort field in Browse and Search.
- **Background video playback on iPad** and a full-screen player with
  tap-to-toggle controls.
- **Photos** handled by an image viewer rather than the video player.
- Poster long-press gains **File Info**; more honest transcode/playback error
  reporting and automatic direct-play → transcode fallback.
- New **Story Reader** container for `.storybundle` libraries.

---

## Install

1. Open `ContainerPlus-1.0.2.dmg` and drag **ContainerPlus** to Applications.
2. First launch: right-click → **Open** (or approve in System Settings →
   Privacy & Security) if Gatekeeper prompts.
3. Verify the download if you like:
   `shasum -a 256 ContainerPlus-1.0.2.dmg` should match the SHA-256 above.

## Notes & caveats

- Plex playback of some codecs relies on the server's transcoder; transcode
  parameters use sensible defaults and can be tuned per server.
- On iPad, reaching a Plex server on your LAN triggers the system local-network
  permission prompt.
- The Plex Player and Story Reader containers mirror the standalone
  **PlexPlus** and **Story Reader** apps; fixes are ported between projects by
  hand.
