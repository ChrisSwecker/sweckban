# Sweckban.app — build kit

Native Mac wrapper for Sweckban (WKWebView + Swift, ~1 MB, no Electron).

## Build (one time, per Mac or copy the .app over)

    xcode-select --install   # skip if you already have Command Line Tools
    ./build.sh

Produces `Sweckban.app`. Drag to /Applications or run it from anywhere.

## Data

Saves to `~/Desktop/Sweckban/sweckban-data.json` on every change — put that
folder under iCloud sync (Desktop & Documents sync covers it) and boards
follow you between Macs. When the app regains focus it checks the file's
mtime and reloads if iCloud brought in a newer copy.

Backups: before overwriting, the app snapshots the data file to
`~/Desktop/Sweckban/backups/sweckban-YYYYMMDD-HHmmss.json` — at most one
snapshot every 6 hours, keeping the newest 20. Restoring is just copying
a snapshot over `sweckban-data.json`. Tune BACKUP_INTERVAL / BACKUP_KEEP
at the top of `main.swift`.

To relocate the data file, use "Change Location…" in the sidebar — it
copies your current data to the new folder (or adopts an existing
sweckban-data.json found there) and remembers the choice in UserDefaults.
First launch may trigger a one-time macOS prompt to allow folder access.

## Files

- `main.swift`   — the whole app: window, WebView, save bridge, menu
- `sweckban.html`  — the board UI (also works standalone in a browser)
- `Info.plist`   — bundle metadata
- `icon.png`     — source icon; build.sh converts it to .icns
- `build.sh`     — compile + assemble the bundle

The app is ad-hoc signed (local use). If you ever distribute it, you'd
want a Developer ID signature + notarization.
