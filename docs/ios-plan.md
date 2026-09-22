# Sweckban for iPad and iPhone — implementation plan

This is the brief for building the iOS/iPadOS version of Sweckban. It is written for a
fresh Claude Code session that has none of the context of the session that produced it,
so it carries everything that session would otherwise lack. Read it top to bottom before
touching anything, then work the phases in order — each one is independently shippable
and the later ones assume the earlier ones landed.

Kick-off prompt that works: *"Read docs/ios-plan.md and execute Phase 0."*

---

## 1. What exists today (the Mac app)

Sweckban is a kanban + multi-year planner app. **The entire UI is one file,
`sweckban.html`** (HTML+CSS+JS, ~3,500 lines), hosted by a thin native shell. On the Mac
the shell is `main.swift` — a single-file AppKit app compiled with `swiftc` by `build.sh`,
no Xcode project. The iOS app reuses `sweckban.html` unchanged wherever possible and gets
its own shell.

```
sweckban-app_2/
  sweckban.html            the whole UI — shared with iOS, single source of truth
  main.swift               Mac shell: WKWebView host, bridge, persistence, iCloud
  build.sh                 Mac build: swiftc, icon, sign (Developer ID + hardened runtime)
  notarize.sh              Mac notarization; needs `xcrun notarytool` profile "sweckban"
  Sweckban.entitlements    iCloud container entitlements (Mac)
  embedded.provisionprofile  Developer ID profile granting the iCloud container (Mac)
  make-icon.js             generates icon.svg / icon-small.svg / icon.png
  tests/merge.test.js      the only tests: `node tests/merge.test.js` (17, no deps)
  Info.plist, icon.png, README.md
```

Git: `github.com/ChrisSwecker/sweckban`, branch `main`. **Branch before committing;
never commit to `main` directly.** Commit messages end with the Co-Authored-By line the
session is given.

### Identifiers (all already registered on the developer portal)

| Thing | Value |
|---|---|
| Team | `2V6HCLJ5U4` (Chris Swecker) |
| App ID | `com.swecker.sweckban` — explicit, registered for iOS/iPadOS/macOS, iCloud capability on |
| iCloud container | `iCloud.com.swecker.sweckban` — created and assigned to the App ID |
| Mac signing | `Developer ID Application: Chris Swecker (2V6HCLJ5U4)` |
| iOS dev signing | two `Apple Development: Chris Swecker (65R9PAXBTL)` certs are installed — Xcode automatic signing will work |

The iOS app **should use the same App ID** `com.swecker.sweckban`. App IDs are
platform-agnostic; only the provisioning profile is per-platform, and Xcode's automatic
signing creates the iOS one. Sharing the App ID is what lets both apps share the
container without any further portal work.

### Data model (the synced JSON)

```
state = {
  schema: 2,
  activeBoard: <board id>,                 // see Phase 0 — moving out of the file
  boards: [{ id, name, type: 'kanban'|'planner', updatedAt,
             lists: [{ id, name, updatedAt, cards: [{ id, title, desc, labels[], due, archived, updatedAt }] }],   // kanban
             tasks: [{ id, title, desc, start, end, assignees: [{type:'dept'|'person', id}], color, milestones: [{id,label,date}], archived, updatedAt }] }],  // planner
  people:      [{ id, name, handle, color, updatedAt }],
  departments: [{ id, name, handle, color, updatedAt }],
  tombstones:  { <id>: <deletedAt ms>, ... }   // hard deletes; pruned after 90 days
}
```

Every entity has `updatedAt` (ms). `save()` in the JS diffs against the last snapshot and
stamps only what changed (`stampChanges`); containers compare shallowly including child-id
order, so reordering cards bumps the list, not the board. Deletes call `tomb()`.
`normalize()` migrates older files and writes `schema`. A file with a higher `schema` than
the app knows opens **read-only** (`readOnlyReason`).

### The JS ↔ native bridge (port this exactly)

The shell injects, at document start, before the page's own script runs:

```js
window.__SWECKBAN_NATIVE = true;
window.__SWECKBAN_DATA_PATH = "<path shown in Settings>";
window.__SWECKBAN_BOOT_DATA = "<entire JSON file as a string>";   // omitted if no file
```

Escape these with JSON serialization (the Mac uses `jsString()` — wrap the string in a
JSON array and strip the brackets). The page decides it is native when
`window.__SWECKBAN_NATIVE && window.webkit.messageHandlers.sweckban` both exist.

JS → native, via `webkit.messageHandlers.sweckban.postMessage({...})`:

| `cmd` | payload | what the shell does |
|---|---|---|
| `save` | `data`: full JSON string | write the data file (coordinated, atomic) |
| `badge` | `count`: int | app badge = count of due/overdue cards (0 clears) |
| `revealData` | — | Mac: reveal in Finder. **iOS: hide the button** (Phase 0 adds a platform flag) |
| `changeLocation` | — | Mac: folder picker. **iOS: not applicable, hide** |

Native → JS, via `evaluateJavaScript`:

| function | purpose |
|---|---|
| `window.__sweckbanApplyExternal(jsonString)` | a changed file arrived (other device). **Merges** with in-memory state, closes any open editor first, writes the merge back if it kept local edits. |
| `window.__sweckbanCurrentState()` | returns full JSON, or `""` if disk already matches — used for a flush at quit/background |
| `window.__sweckbanMenu(action)` | actions: `settings newBoard newPlanner newCard export import archive toggleTheme toggleSidebar togglePeople toggleFitWidth nextBoard prevBoard` |
| `window.__sweckbanUndo()` / `__sweckbanRedo()` | board-level undo/redo |
| `window.__sweckbanRelocated(path, contents)` | Mac only (Change Location) |

**Security rules the Mac shell enforces, and iOS must too:** a `WKNavigationDelegate` that
allows only the bundled HTML file URL and cancels everything else (open `http(s)` links
externally); and the message handler ignores any message whose `frameInfo` isn't the main
frame of that same URL. Without this, a dropped/linked page inherits the ability to
overwrite the data file.

### Persistence and sync (port `main.swift`'s pattern)

The file lives in the iCloud container's `Documents/` folder as `sweckban-data.json`:
`~/Library/Mobile Documents/iCloud~com~swecker~sweckban/Documents/` on the Mac. The Mac
app also keeps rotating backups in `Documents/backups/` (every 6h, keep 20) — they sync
too, which is fine.

`main.swift` has the reference implementation; port these pieces, they are all plain
Foundation and work identically on iOS:

- `coordinatedRead(path)` / `coordinatedWrite(text, to:)` — every read and write goes
  through `NSFileCoordinator`, passing the presenter below so our own writes don't echo.
- `DataFileWatcher: NSFilePresenter` — `presentedItemDidChange` → `syncFromDisk()`.
  `syncFromDisk` compares **content** to `lastWrittenJSON` (never mtime — iCloud can
  restore an older mtime) and calls `__sweckbanApplyExternal` on change. Guard against a
  nil web view.
- `ensureDownloaded(path)` — if `isUbiquitousItem` and downloading status isn't
  `.current`, `startDownloadingUbiquitousItem` and wait (8s cap). An undownloaded file
  reads as nil, which is indistinguishable from corruption otherwise.
- Resolve the container with `url(forUbiquityContainerIdentifier: "iCloud.com.swecker.sweckban")`
  **off the main thread** (it can block for seconds on iOS, unlike the Mac).
- Quit flush: the Mac's `applicationShouldTerminate` pulls `__sweckbanCurrentState()` and
  writes it with a 2s watchdog. iOS has no quit — do this on `sceneDidEnterBackground`
  (and `sceneWillResignActive`), synchronously enough to beat suspension.

#### The gotcha that cost an hour on the Mac

`com.apple.application-identifier` **must** be in the app's entitlements or the iCloud
entitlements are silently inert: the app launches, signing validates, and
`url(forUbiquityContainerIdentifier:)` returns `nil` in 0.00s — which looks exactly like
"the container hasn't propagated yet". Xcode adds this automatically when you turn on the
iCloud capability; if you ever hand-edit entitlements, keep it. To diagnose any container
problem: `/usr/bin/log stream --predicate 'process == "bird" OR process == "cloudd"'`
while the app runs (note: `/usr/bin/log`, because zsh has a `log` builtin), and
`brctl status` to list containers the daemon knows.

### The merge (already done — do not reimplement)

`sweckban.html` contains a pure block between `// MERGE:BEGIN` and `// MERGE:END`:
`mergeStates(mine, theirs)`, per-entity newest-wins, tombstones beat older edits, an edit
newer than a delete resurrects, container order follows the later-touched container,
ties break on content so devices converge, `activeBoard` excluded. `sameData(a, b)` is a
key-order-insensitive equality that decides whether to write a merge back.
`tests/merge.test.js` extracts that block by the markers and runs it in Node — **keep the
block free of DOM/app-state references** or the tests break. Run the tests after any
change to the block.

---

## 2. Decisions already made

1. **Separate Xcode project for iOS, in `ios/`.** The Mac app keeps its hand-built,
   notarized pipeline — it works and there is no reason to risk it. Don't try to fold the
   Mac target into Xcode.
2. **One `sweckban.html`.** The iOS target references `../sweckban.html` (add it to the
   target as a *reference*, not a copy — check the file's path in the File Inspector is
   relative to the group and resolves outside `ios/`). Platform differences are handled
   inside the HTML via a flag the shell injects (Phase 0), never by forking the file.
3. **Same App ID and container** as the Mac app (table above).
4. **iPad first, iPhone second.** The current layout assumes ≥760px width; iPad landscape
   (1024–1366pt) works as-is and iPad portrait (768–834pt) is at the edge of fine. iPhone
   needs a real responsive pass and is its own phase.
5. **Coordinated file access, not `UIDocument`.** Matching the Mac's pattern keeps one
   mental model and one set of bugs. `UIDocument` would be idiomatic but doesn't buy
   anything the coordinator + presenter don't already provide here.
6. **Development signing on your own devices; no App Store, no TestFlight** for now.
   With a paid account the dev profile lasts a year. Revisit if anyone else needs it.

---

## 3. Phases

### Phase 0 — Prepare the shared code (do this on the Mac, ship it, then start iOS)

These are changes to `sweckban.html`/`main.swift` that the iOS app needs and that are far
easier to test on the Mac where everything already works. Each is small. Build with
`./build.sh`, copy `Sweckban.app` to `~/Desktop` with `ditto --noextattr --norsrc`, and
run `node tests/merge.test.js`. Re-run `./notarize.sh` before handing the Mac build to
anyone.

- [x] **Platform flag.** Shell injects `window.__SWECKBAN_PLATFORM = "macos" | "ios"`. In
      `initSaveFile()`'s native branch, show the *Reveal* and *Change Location* buttons only
      on macOS; on iOS show a one-line note ("Synced through iCloud") instead. Nothing else
      should branch on platform unless it must.
- [x] **Move `activeBoard` out of the synced file.** It's device-local UI state; today it's
      in the JSON, so switching boards on one device can nudge another. Keep it in
      `localStorage` (key `sweckban.activeBoard`), fall back to the first board, and stop
      writing it to disk. `normalize()` should tolerate a file that still has it.
      Update `sameData()`'s exclusion and the tests accordingly.
- [x] **Export via the bridge.** Export currently builds a Blob and clicks an `<a download>`
      (`exportBtn` handler) — that does nothing in an iOS `WKWebView`. Add a native cmd
      `{cmd:'export', name, data}`; when `NATIVE`, post it instead of the anchor trick. Mac:
      `NSSavePanel`. iOS (Phase 1): share sheet / Files export. Import already works —
      `<input type=file>` is native on iOS with no delegate needed.
- [x] **NSFileVersion conflicts.** iCloud Documents creates *conflict versions* when two
      devices write the same file while offline (`NSFileVersion.unresolvedConflictVersionsOfItem(at:)`).
      Nobody handles them yet, on either platform. Add to the Mac shell, in the same file
      as the watcher: on launch and on every `presentedItemDidChange`, enumerate unresolved
      versions, read each, feed each through `__sweckbanApplyExternal` (the merge is
      commutative and idempotent, so order doesn't matter), then mark them resolved and
      remove them. `NSFilePresenter` also has `presentedItemDidGain(_ version:)` — use it.
      Test on the Mac by creating a conflict deliberately (write the file from a second
      process while iCloud is paused, or use two Macs). This is the one piece of Phase 0
      that is genuinely tricky; it is also the one that will bite first with a phone.
- [x] **Pointer-event card drag (groundwork).** Cards and list headers use HTML5
      drag-and-drop (`draggable = true`, `dragstart/dragover/drop` in `renderList`/`renderCard`).
      That works on iPad Safari but not iPhone, and feels wrong on touch anyway. The
      planner bar drag was already converted to pointer events (`attachBarDrag`,
      `touch-action: none`) — use it as the model. Doing this on the Mac first means it's
      tested with a mouse before touch complicates it. Keep the `<3px movement = click`
      rule.

Acceptance: Mac app behaves exactly as before for the user; tests pass; a deliberately
created conflict version is merged and cleared.

### Phase 1 — iPad shell with full sync parity

- [x] `ios/Sweckban.xcodeproj`, iOS 17+ deployment target, SwiftUI `App` hosting a
      `UIViewRepresentable` around `WKWebView` (or plain UIKit — either is fine; keep it
      to two or three files). Bundle ID `com.swecker.sweckban`, automatic signing, team
      `2V6HCLJ5U4`. Turn on **iCloud → iCloud Documents** with container
      `iCloud.com.swecker.sweckban` in Signing & Capabilities; confirm the generated
      `.entitlements` contains `application-identifier`, both container-identifier keys,
      and `icloud-services = CloudDocuments`.
- [x] Add `../sweckban.html` to the target as a referenced bundle resource. Load with
      `loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())`.
- [x] Port the bridge and persistence from `main.swift` (section 1). Same handler name
      `sweckban`, same injected globals plus `__SWECKBAN_PLATFORM = "ios"`, same
      navigation lockdown and frame check, coordinated I/O, presenter, `ensureDownloaded`,
      content-based `syncFromDisk`, background flush via `__sweckbanCurrentState()`.
- [x] **First-launch states**, in order: resolving the container (background thread,
      show a spinner); container file present but not downloaded (`ensureDownloaded` with
      the spinner still up); no file at all (a Mac hasn't synced yet — start with the seed
      board, and the merge will reconcile when the Mac's file arrives); file unreadable
      (refuse to boot with a message, never seed over it — same rule as the Mac).
- [x] `WKUIDelegate` for `alert`/`confirm` → `UIAlertController`. The page uses both.
- [x] `badge` cmd → `UNUserNotificationCenter` badge (needs `.badge` authorization; ask
      once, silently skip if denied).
- [x] `export` cmd → write to a temp file and present `UIActivityViewController`.
- [x] `WKWebView` setup: `scrollView.bounces = false`, `contentInsetAdjustmentBehavior = .never`
      (the page owns safe areas), `allowsBackForwardNavigationGestures = false`.
- [x] Viewport meta: `width=device-width, initial-scale=1, viewport-fit=cover`. Add
      `padding: env(safe-area-inset-*)` on the app frame. Do **not** disable user zoom
      with `maximum-scale`; use `touch-action: manipulation` on the body to kill
      double-tap zoom instead.
- [x] Hardware keyboard on iPad. **The assumption here was wrong**: none of the shortcuts
      worked through the web layer. The page listens for `keydown` with `metaKey`, which is
      all the Mac needs, but iPadOS routes Command chords through the responder chain as
      `UIKeyCommand`s and they never reach web content unless the page holds focus — so
      every shortcut silently did nothing. Fixed by registering 13 `UIKeyCommand`s in the
      shell and forwarding them through the same `__sweckbanMenu` bridge the Mac menu bar
      uses, with `search`/`undo`/`redo` added to that switch. All verified on the device.
      `wantsPriorityOverSystemBehavior` is required or the system keeps some for itself,
      which makes ⌘Z the delicate one: it has to hand text undo back, via
      `document.execCommand` when a field has focus (verified — typing then ⌘Z undoes the
      typing, not the board).
      **Known gap:** holding ⌘ does not raise the iPadOS shortcut overlay, with both `title`
      and `discoverabilityTitle` set. That appears to need the full `UIMenuBuilder` menu
      system — disproportionate machinery for a discoverability HUD. The shortcuts work;
      they just don't announce themselves.
- [x] Undo/redo affordance without a menu bar: a small toolbar in the web UI when
      `__SWECKBAN_PLATFORM === "ios"`, or support shake-to-undo by forwarding
      `motionEnded` to `__sweckbanUndo`. Toolbar is more discoverable.

**ACCEPTANCE TESTS — ALL SIX PASS ON REAL HARDWARE, 2026-09-22** (iPad Pro 12.9-inch, signed device build,
same iCloud account as the Mac, against the live container and real boards — a backup was taken
first):

1. **Same boards on iPad and Mac — PASS.** All four boards, nine people and four departments
   matched the container exactly on first launch.
2. **Edit propagates both ways without relaunching — PASS.** A Mac-side write appeared on the
   iPad in under 25s; a card created on the iPad reached the Mac container.
3. **Offline edits to different cards both survive — PASS.** iPad in Airplane Mode edited one
   card, the Mac edited another; on reconnect both devices held both edits, nothing lost, no
   conflict version left behind.
4. **Offline edits to the same card, later one wins — PASS, and this is the one that proved the
   Phase 0 conflict code.** iCloud created a real conflict version and the Mac app logged:
   `gained conflict version …_1mrpq.json` → `resolving 1 conflict version(s)` (twice, harmlessly —
   the handler is idempotent by design) → `applying external change`. Both devices converged on
   the later edit; `unresolvedConflictVersionsOfItem` returned 0 afterwards.
5. **Hard kill and relaunch — PASS (persistence).** The iPad app was terminated outright and
   relaunched with state intact. The *mid-edit flush race* specifically was not forced, since
   every edit already posts `save` immediately.
6. **External links open in Safari — PASS.** A URL dragged from Safari and dropped onto the app
   opened in Safari; the board was still there afterwards and the data file was untouched. Note
   the page has no clickable links at all — the only `<a>` is the export-download trick, which
   native builds bypass, and card text renders as text nodes — so a dropped link is the only way
   to reach this delegate today.

**TRAP WORTH REMEMBERING:** the first run of test 3 proved the merge but *not* the conflict code,
because the Mac app still running was a pre-Phase-0 binary started before the build. The giveaway
was `activeBoard` still present at the top level of the synced file — only the old build writes it.
Restarting the Mac app on the new build stripped the key immediately and made test 4 meaningful.
Check which binary is actually *running*, not which one is on disk.

**Status:** built and running on the iPad simulator. Verified there: boot, the save bridge
writing to disk, a coordinated external write applying live without relaunch (and merging
rather than clobbering a local edit), the iOS Settings copy, export via the share sheet,
safe-area insets, tap-to-open-card, and a background/foreground round trip. The simulator
has no ubiquity container (an unsigned build gets no entitlements), so it exercised the
local-Documents fallback — which means **none of the numbered acceptance tests below are
done**; they all need a signed device build on the real iCloud account. The hardware-keyboard
item is also untested.

Acceptance (all but #6 now verified on real hardware — see above):
1. Same boards on iPad and Mac.
2. Edit on the Mac → appears on the iPad within seconds without relaunching, and vice versa.
3. Put both offline, edit a *different* card on each, reconnect → both edits survive on
   both devices, no conflict version left behind.
4. Put both offline, edit the *same* card on each, reconnect → the later edit wins on both.
5. Background the iPad app mid-edit, kill it from the app switcher, relaunch → the edit
   is on disk and on the Mac.
6. A dropped/tapped external link opens in Safari, never inside the app.

### Phase 2 — Touch

- [x] Card and list drag on touch using the Phase 0 pointer-event implementation; on
      iPhone, add a "Move to…" action in the card editor as the accessible alternative.
- [x] `:hover` audit — there are ~20 `:hover` rules; on touch they stick after a tap.
      Wrap them in `@media (hover: hover)`.
- [x] Hit targets: cards, list headers, the `+ Add card` input, planner milestone diamonds
      and bar handles (currently 8px wide — too small for a finger; make the handle's
      touch area ≥ 24px while keeping its visual width).
- [x] Autocomplete popover for `@mentions` — check it doesn't get hidden behind the
      on-screen keyboard; the `ac` module positions it under the input.
- [x] ~~Long-press on a card opens the editor~~ — **superseded.** Long press is what arms
      the drag, so it can't also open the editor. Tap opens it, which it already did; the
      hold only starts once the finger has been still, so taps aren't swallowed.

**Status:** done and verified on the iPad simulator. A quick swipe still scrolls the
column (it stands down the moment the finger moves past TOUCH_SLOP); a long press picks
the card up; holding at an edge auto-scrolls — a card was dragged from index 1 to index 45
of a 47-card column, far past anything visible when the drag began. The list picker moves
a card with no gesture at all. Mouse drag re-verified in the browser, unchanged.
`TOUCH_HOLD_MS` is 450 and wants tuning on real hardware — the simulator can't tell you
whether a hold feels responsive or sluggish.

### Phase 3 — iPhone layout

The UI assumes a sidebar plus a wide board. Under ~600px:

- [x] Sidebar becomes a slide-over sheet opened from a top bar (boards, people, departments
      all live there already; nothing new, just hidden by default).
- [x] Kanban: columns become full-width pages in a horizontally snapping scroller
      (`scroll-snap-type: x mandatory`, each `.list` ~88vw). Keep the existing DOM.
- [x] Planner: force month zoom, narrow the name column, hide swimlane grouping.
      **Not** read-only: the bars already carry `touch-action: none` and Phase 2 gave the
      handles and diamonds finger-sized hit areas, so editing works and saying "read-only"
      would have been a bigger claim than the code needed.
- [x] Modals go full-screen; the milestone rows and assignee checklists need scroll room.
- [x] Verified on the Simulator at 390pt (iPhone 17e — no SE runtime is installed, so this
      is the narrowest available; 15pt wider than an SE) and at 440pt (17 Pro Max).

**Status:** done. Two things worth carrying forward. **iOS zooms the page when you focus a
control whose font is under 16px** — our 13px fields produced a 1.23x zoom that left the
layout correct but pushed the right edge of every field off-screen; form controls are now
16px under `pointer: coarse`, which is the fix that keeps pinch zoom (`maximum-scale=1`
would not). And forcing month zoom meant the timeline opened in January with the tasks
months off-screen, so the planner now opens scrolled to today — that also changes the Mac,
mildly (70px at year zoom) and for the better.

### Phase 4 — Polish and icon

- [x] **iOS icon is a different asset.** iOS wants a 1024×1024 **opaque** square — no
      alpha, no baked shadow, no rounded corners; the system masks it. The Mac
      `icon.svg` is a squircle with a drop shadow on a transparent canvas and **will be
      rejected/warned on**. Add an `ios` variant to `make-icon.js`: fill the whole canvas
      with the shell gradient, same three Gantt bars centred (they'll need to sit a bit
      larger since there's no inset), no shadow, no rim stroke, write `ios/AppIcon.png`.
      Xcode 14+ accepts a single 1024 asset.
- [x] Launch screen matching the app background so the web view's load doesn't flash.
- [x] Settings copy on iOS (`storageNote`): where the data is, that it syncs via iCloud,
      how to export.
- [x] Update `README.md` with the iOS build steps.

**Status:** done. The iOS icon is generated by `make-icon.js` alongside the Mac pair and
lands in `ios/Sweckban/Assets.xcassets`. Note it has to be **opaque**: rsvg-convert always
writes RGBA and there is no ImageMagick on this machine, so the alpha channel is dropped by
round-tripping through BMP with `sips` (`hasAlpha: no` verified). The launch screen needed a
real `Info.plist` — Xcode exposes `INFOPLIST_KEY_UILaunchScreen_Generation` but **no build
setting for the colour**, so the generated plist can't name one; `INFOPLIST_FILE` plus
`GENERATE_INFOPLIST_FILE` merges the one key in. Sampled the first frame after launch: RGB
(18,18,20), matching the app background, so there is no white flash.

---

## 4. How to verify (tooling that exists in the session)

- **`node tests/merge.test.js`** after any change near the merge block.
- **iOS Simulator tool** (`mcp__Claude_Code_iOS_Simulator__control`): build with the
  session's iOS build tool or `xcodebuild`, `launch` the `.app`, `attach` the panel so the
  user can watch, `inspect`/`tap`/`screenshot` for verification. Sign the simulator into
  the same iCloud account for sync tests; if simulator iCloud is flaky, the shell's local
  fallback path (no container → app's Documents dir) still lets you exercise everything
  but sync.
- **Mac side of a sync test:** the Mac app logs to stderr — launch it with
  `open --stderr <file> --stdout <file> ~/Desktop/Sweckban.app` and watch for
  `Sweckban: applying external change …` and `Sweckban: watching …`.
- **Never test against the real data file.** For the Mac: `defaults write
  com.swecker.sweckban dataDir <scratch dir>` and `useICloud -bool NO`, then `defaults
  delete` both keys when done. Real data lives in the container path above; there's also
  an untouched pre-migration copy at `~/Desktop/Sweckban/sweckban-data.json`.
- **Simulating another device:** a separate process doing a *coordinated* write
  (`NSFileCoordinator … coordinate(writingItemAt:options:.forReplacing)`) of a modified
  file is what triggers the presenter; a plain write may not.

## 5. Non-goals for now

CloudKit / per-record sync (the file model plus merge is holding up; revisit only if
conflict handling proves painful), App Store distribution, Apple Watch, widgets,
notifications beyond the badge, a Mac Catalyst build (the AppKit shell is better).

## 6. Known rough edges to keep in mind

- Backups are 6h × 20 ≈ five days of history. Not an iOS concern, but a deletion noticed
  a week later is unrecoverable. Separate task.
- There's no CSP in `sweckban.html`. Cheap defense-in-depth; separate task.
- The Mac app was notarized before Phase 0; re-notarize after (`./notarize.sh`).
