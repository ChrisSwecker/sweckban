# Sweckban — build kit

A kanban + multi-year planner, as a Mac app and an iPhone/iPad app.

Both are a thin native shell around **one file**, `sweckban.html`, which holds
the entire UI. The shells own persistence and sync; the page owns everything
you see. Keep it that way — platform differences go behind the
`__SWECKBAN_PLATFORM` flag the shell injects, not into a second copy of the
page.

## Build the Mac app

    xcode-select --install   # skip if you already have Command Line Tools
    ./build.sh

Produces `Sweckban.app`. Drag it to /Applications or run it from anywhere.

`build.sh` signs with a Developer ID certificate when one is installed
(override with `SWECKBAN_SIGN_ID`, force ad-hoc with `SWECKBAN_SIGN_ID=-`)
and turns on the hardened runtime. To hand the app to anyone else, run
`./notarize.sh` afterwards — it needs a one-time
`xcrun notarytool store-credentials sweckban …` profile.

## Build the iOS app

    open ios/Sweckban.xcodeproj

Pick a simulator or your device and run. Or from the command line:

    xcodebuild -project ios/Sweckban.xcodeproj -scheme Sweckban \
      -configuration Debug -sdk iphonesimulator \
      -destination 'name=iPhone 17' -derivedDataPath ios/build \
      CODE_SIGNING_ALLOWED=NO build

The simulator build skips signing, which also means it gets **no
entitlements** — so the iCloud container never resolves there and the app
falls back to its own Documents directory. Everything works except sync;
Settings says "On this device only" when that happens, so you can tell the
two apart at a glance. **Testing sync needs a signed build on a real
device.** Automatic signing handles that: select the target, Signing &
Capabilities, team `2V6HCLJ5U4`.

The project deliberately references `../sweckban.html` rather than keeping a
copy, so editing the page changes both apps.

## Data and sync

Both apps keep `sweckban-data.json` in the shared iCloud container
`iCloud.com.swecker.sweckban`. On the Mac that is

    ~/Library/Mobile Documents/iCloud~com~swecker~sweckban/Documents/

On iOS it is the app's own container, which is private — it doesn't show up
in Files. Use **Export JSON** in Settings to get a copy out.

Every read and write goes through `NSFileCoordinator`, and an
`NSFilePresenter` applies changes as they land, so an edit on one device
shows up on the other within seconds without relaunching. Changes are merged
per entity rather than last-writer-wins: each entity carries `updatedAt` and
each delete leaves a tombstone, so two devices editing different things
offline both keep their work. Unresolved iCloud conflict versions are fed
through the same merge and then cleared.

Which board you have open is *not* synced — it lives in `localStorage` per
device.

Backups (Mac only): before overwriting, the app snapshots the data file to
`backups/sweckban-YYYYMMDD-HHmmss.json` next to it — at most one every 6
hours, keeping the newest 20. Restoring is just copying a snapshot back over
`sweckban-data.json`. Tune `BACKUP_INTERVAL` / `BACKUP_KEEP` at the top of
`main.swift`.

"Change Location…" (Mac only) moves the data file elsewhere and remembers
the choice; it also opts out of the iCloud container, so the next launch
won't quietly move back.

## Tests

    node tests/merge.test.js

18 tests, no dependencies. They extract the block between `// MERGE:BEGIN`
and `// MERGE:END` out of `sweckban.html` and run it in Node, so they test
the shipped source with no build step. Keep that block free of DOM and app
state or they stop working.

Note that `xcodebuild` does **not** check the page's JavaScript — it copies
the HTML as a resource. A syntax error there builds fine and fails at
runtime.

## Files

- `sweckban.html`   — the whole UI, shared by both apps (also runs standalone in a browser)
- `main.swift`      — Mac shell: window, WebView, bridge, persistence, menu bar
- `build.sh`        — Mac build: compile, icon, sign
- `notarize.sh`     — Mac notarization
- `ios/`            — Xcode project and the iOS shell (3 Swift files)
- `make-icon.js`    — regenerates the icon art, Mac and iOS
- `tests/`          — the merge tests
- `docs/ios-plan.md` — the plan the iOS app was built from

## Icons

    node make-icon.js

Writes `icon.svg` / `icon-small.svg` / `icon.png` for the Mac, and
`icon-ios.svg` plus the 1024 `AppIcon.png` in the iOS asset catalog. Needs
`rsvg-convert` (`brew install librsvg`) to refresh the PNGs.

The two platforms want opposite things and that is why there are two
variants. macOS wants a squircle with a drop shadow on a transparent canvas.
iOS wants a full-bleed **opaque** square with no alpha and no corners of its
own — the system masks it, and a baked-in squircle would be masked twice.
