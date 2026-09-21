import Cocoa
import WebKit

// ============================================================
// Sweckban — native wrapper
// Data location: default below; changeable in-app via
// "Change Location…" (persisted in UserDefaults under "dataDir").
// ============================================================
var DATA_DIR = UserDefaults.standard.string(forKey: "dataDir")
    ?? ("~/Desktop/Sweckban" as NSString).expandingTildeInPath
var DATA_FILE: String { DATA_DIR + "/sweckban-data.json" }

// Rotating backups: snapshot the data file before overwriting it, at most
// once per BACKUP_INTERVAL, keeping the newest BACKUP_KEEP snapshots.
var BACKUP_DIR: String { DATA_DIR + "/backups" }
let BACKUP_INTERVAL: TimeInterval = 6 * 60 * 60  // 6 hours
let BACKUP_KEEP = 20

func maybeBackup() {
    let fm = FileManager.default
    guard fm.fileExists(atPath: DATA_FILE) else { return }
    try? fm.createDirectory(atPath: BACKUP_DIR, withIntermediateDirectories: true)

    let existing = ((try? fm.contentsOfDirectory(atPath: BACKUP_DIR)) ?? [])
        .filter { $0.hasPrefix("sweckban-") && $0.hasSuffix(".json") }
        .sorted()  // timestamp-named, so lexical order == chronological

    if let newest = existing.last,
       let attrs = try? fm.attributesOfItem(atPath: BACKUP_DIR + "/" + newest),
       let mod = attrs[.modificationDate] as? Date,
       Date().timeIntervalSince(mod) < BACKUP_INTERVAL {
        return  // recent snapshot exists
    }

    let df = DateFormatter()
    df.dateFormat = "yyyyMMdd-HHmmss"
    try? fm.copyItem(atPath: DATA_FILE,
                     toPath: BACKUP_DIR + "/sweckban-" + df.string(from: Date()) + ".json")

    let all = ((try? fm.contentsOfDirectory(atPath: BACKUP_DIR)) ?? [])
        .filter { $0.hasPrefix("sweckban-") && $0.hasSuffix(".json") }
        .sorted()
    if all.count > BACKUP_KEEP {
        for old in all.prefix(all.count - BACKUP_KEEP) {
            try? fm.removeItem(atPath: BACKUP_DIR + "/" + old)
        }
    }
}

func jsString(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [s])
    var str = String(data: data, encoding: .utf8)!
    str.removeFirst() // strip [
    str.removeLast()  // strip ]
    return str
}

// ============================================================
// Where the data lives
// ============================================================
// Preference order:
//   1. The app's own iCloud container — the only location an iOS/iPadOS build can also
//      read, and one the user can't drag somewhere else by accident.
//   2. A folder chosen with "Change Location…" (UserDefaults "dataDir").
//   3. ~/Desktop/Sweckban.
//
// macOS grants the com.apple.developer.icloud-* entitlements only to a Developer ID app
// carrying a matching provisioning profile. Until embedded.provisionprofile is in the
// bundle we don't even ask for the container: asking is a blocking call that can take
// seconds, and the answer would be nil anyway.
let ICLOUD_CONTAINER_ID = "iCloud.com.swecker.sweckban"

func iCloudDocumentsDir() -> String? {
    guard UserDefaults.standard.object(forKey: "useICloud") as? Bool ?? true else { return nil }
    guard FileManager.default.fileExists(
            atPath: Bundle.main.bundlePath + "/Contents/embedded.provisionprofile") else { return nil }
    guard let container = FileManager.default
            .url(forUbiquityContainerIdentifier: ICLOUD_CONTAINER_ID) else { return nil }
    let docs = container.appendingPathComponent("Documents")
    try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    return docs.path
}

// ============================================================
// Coordinated file access
// ============================================================
// Every read and write goes through NSFileCoordinator. The data file is already an iCloud
// item for anyone using Desktop & Documents sync, and will be one in the app's container
// later, so the sync daemon may be replacing it at any moment. Coordination is what stops
// us reading a half-written file or writing over one that just landed — and it is
// mandatory for anything inside a ubiquity container.

final class DataFileWatcher: NSObject, NSFilePresenter {
    static let shared = DataFileWatcher()
    var onChange: (() -> Void)?

    private var url = URL(fileURLWithPath: DATA_FILE)
    private let queue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q
    }()

    var presentedItemURL: URL? { url }
    var presentedItemOperationQueue: OperationQueue { queue }

    // start() re-reads DATA_FILE so relocating is just stop-then-start.
    func start() {
        url = URL(fileURLWithPath: DATA_FILE)
        NSFileCoordinator.addFilePresenter(self)
        NSLog("Sweckban: watching %@", url.path)
    }
    func stop() { NSFileCoordinator.removeFilePresenter(self) }
    func relocate() { stop(); start() }

    // Someone else wrote the file: a change arriving from another Mac, or a hand edit.
    // Our own writes pass this presenter to the coordinator, so they don't come back here.
    func presentedItemDidChange() { DispatchQueue.main.async { self.onChange?() } }
    func presentedSubitemDidChange(at url: URL) { presentedItemDidChange() }
}

func coordinatedRead(_ path: String) -> String? {
    var text: String?
    var coordError: NSError?
    NSFileCoordinator(filePresenter: DataFileWatcher.shared)
        .coordinate(readingItemAt: URL(fileURLWithPath: path), options: [], error: &coordError) { url in
            text = try? String(contentsOf: url, encoding: .utf8)
        }
    return text
}

func coordinatedWrite(_ text: String, to path: String) throws {
    var writeError: Error?
    var coordError: NSError?
    NSFileCoordinator(filePresenter: DataFileWatcher.shared)
        .coordinate(writingItemAt: URL(fileURLWithPath: path),
                    options: .forReplacing, error: &coordError) { url in
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { writeError = error }
        }
    if let e = writeError { throw e }
    if let e = coordError { throw e }
}

// An iCloud file that hasn't been downloaded yet reads as nil, which is indistinguishable
// from a corrupt file — and we now refuse to boot on an unreadable file, so ask for it and
// wait briefly. Already-present files return immediately, so this is free in the normal case.
func ensureDownloaded(_ path: String) {
    let url = URL(fileURLWithPath: path)
    let fm = FileManager.default
    guard fm.isUbiquitousItem(at: url) else { return }
    let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey]
    func current() -> Bool {
        (try? url.resourceValues(forKeys: keys))?.ubiquitousItemDownloadingStatus == .current
    }
    if current() { return }
    try? fm.startDownloadingUbiquitousItem(at: url)
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        if current() { return }
    }
    NSLog("Sweckban: timed out waiting for iCloud to download %@", path)
}

class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var appURL: URL?             // the bundled sweckban.html — the only page ever allowed
    var lastMod: Date = .distantPast
    var saveErrorShown = false   // one-shot guard so a failing disk doesn't spam alerts
    var bridgeLogged = false
    var lastWrittenJSON = ""     // what we last put on disk, so a sync-in is distinguishable from our own write

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: DATA_DIR, withIntermediateDirectories: true)

        // One-time migration from the old Swecko layout
        let oldFile = ("~/Desktop/Swecko/swecko-data.json" as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: DATA_FILE),
           FileManager.default.fileExists(atPath: oldFile) {
            try? FileManager.default.copyItem(atPath: oldFile, toPath: DATA_FILE)
        }

        adoptICloudContainerIfAvailable()
        resolveMissingDataFile()

        // Watch the data file so a change synced from another device applies as it lands,
        // rather than waiting for the window to be focused.
        DataFileWatcher.shared.onChange = { [weak self] in self?.syncFromDisk() }
        DataFileWatcher.shared.start()

        let config = WKWebViewConfiguration()
        let ucc = config.userContentController
        ucc.add(self, name: "sweckban")

        // Inject native flag, data path, and current file contents before the page runs
        var boot = "window.__SWECKBAN_NATIVE = true; window.__SWECKBAN_DATA_PATH = \(jsString(DATA_FILE));"
        ensureDownloaded(DATA_FILE)
        let contents = coordinatedRead(DATA_FILE)
        if let contents = contents, !contents.isEmpty {
            lastWrittenJSON = contents
            boot += "window.__SWECKBAN_BOOT_DATA = \(jsString(contents));"
        } else if contents == nil, FileManager.default.fileExists(atPath: DATA_FILE) {
            // The file is there but we couldn't read it (permissions, a denied Desktop/
            // iCloud access prompt, bad encoding). Booting with an empty board here would
            // make the first save overwrite real data — so stop instead.
            let a = NSAlert()
            a.alertStyle = .critical
            a.messageText = "Sweckban couldn't read its data file"
            a.informativeText = "\(DATA_FILE)\n\nCheck that Sweckban is allowed to access this folder (System Settings ▸ Privacy & Security ▸ Files and Folders) and that the file is readable, then relaunch."
            a.runModal()
            exit(1)
        }
        ucc.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Sweckban"
        window.minSize = NSSize(width: 760, height: 500)
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("SweckbanMain")
        window.makeKeyAndOrderFront(nil)

        if let url = Bundle.main.url(forResource: "sweckban", withExtension: "html") {
            appURL = url
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        updateLastMod()
        buildMenu()
        UserDefaults.standard.set(true, forKey: "hasLaunched")
    }

    // The data file isn't where we expect it — folder moved, renamed, or deleted. On a
    // fresh install that's normal; otherwise ask, rather than silently starting over with
    // an empty board that then becomes "the" data file.
    func resolveMissingDataFile() {
        let fm = FileManager.default
        guard UserDefaults.standard.bool(forKey: "hasLaunched") else { return }
        let originalDir = DATA_DIR
        while !fm.fileExists(atPath: DATA_FILE) {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Sweckban can't find its data file"
            a.informativeText = "Expected it at:\n\(DATA_FILE)\n\n"
                + "If you moved or renamed the Sweckban folder, choose it and Sweckban will keep using it there. "
                + "Starting fresh creates an empty board at the location above."
            a.addButton(withTitle: "Locate Folder…")
            a.addButton(withTitle: "Start Fresh")
            a.addButton(withTitle: "Quit")
            switch a.runModal() {
            case .alertFirstButtonReturn:
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = "Use Folder"
                panel.message = "Choose the folder that contains sweckban-data.json"
                guard panel.runModal() == .OK, let url = panel.url else { continue }
                if fm.fileExists(atPath: url.path + "/sweckban-data.json") {
                    DATA_DIR = url.path
                    UserDefaults.standard.set(DATA_DIR, forKey: "dataDir")
                    // Drop the empty folder we just created at the old location
                    if let left = try? fm.contentsOfDirectory(atPath: originalDir), left.isEmpty {
                        try? fm.removeItem(atPath: originalDir)
                    }
                } else {
                    let b = NSAlert()
                    b.messageText = "No sweckban-data.json in that folder"
                    b.informativeText = "Pick the folder that has the data file directly inside it."
                    b.runModal()
                }
            case .alertSecondButtonReturn:
                return
            default:
                exit(0)
            }
        }
    }

    // ---------- Navigation lockdown ----------
    // Only the bundled page may ever be shown. Left alone, WKWebView navigates to any file
    // or link dropped on the window — and that page would inherit the `sweckban` message
    // handler, i.e. the ability to overwrite the data file. Web links go to the browser.
    func isAppPage(_ url: URL?) -> Bool {
        guard let url = url, let app = appURL, url.isFileURL else { return false }
        return url.standardizedFileURL.path == app.standardizedFileURL.path
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if isAppPage(url) { decisionHandler(.allow); return }
        if let url = url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        NSLog("Sweckban: blocked navigation to %@", url?.absoluteString ?? "(nil)")
        decisionHandler(.cancel)
    }

    // Write the data file (atomic), backing up first. Surfaces a one-time alert if the
    // write fails instead of failing silently. Returns whether the write succeeded.
    @discardableResult
    func writeData(_ data: String) -> Bool {
        maybeBackup()
        do {
            try coordinatedWrite(data, to: DATA_FILE)
            lastWrittenJSON = data
            updateLastMod()
            saveErrorShown = false
            return true
        } catch {
            NSLog("Sweckban: write to %@ failed: %@", DATA_FILE, String(describing: error))
            if !saveErrorShown {
                saveErrorShown = true
                let a = NSAlert()
                a.alertStyle = .critical
                a.messageText = "Sweckban couldn't save your changes"
                a.informativeText = "Writing to\n\(DATA_FILE)\nfailed: \(error.localizedDescription)\n\n"
                    + "Your recent changes are NOT on disk. Check the folder still exists, has free space, "
                    + "and is writable — then make any edit to retry. You can also use Export JSON in Settings to save a copy now."
                a.runModal()
            }
            return false
        }
    }

    // ---------- JS -> native ----------
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "sweckban" else { return }
        // Accept messages only from our own page in the main frame (see isAppPage).
        guard message.frameInfo.isMainFrame, isAppPage(message.frameInfo.request.url) else {
            NSLog("Sweckban: ignored bridge message from %@", message.frameInfo.request.url?.absoluteString ?? "(nil)")
            return
        }
        if !bridgeLogged {
            bridgeLogged = true
            NSLog("Sweckban: bridge accepting messages from %@", message.frameInfo.request.url?.path ?? "?")
        }
        guard let body = message.body as? [String: Any],
              let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "save":
            if let data = body["data"] as? String {
                writeData(data)
            }
        case "revealData":
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: DATA_FILE)])
        case "changeLocation":
            changeLocation()
        case "badge":
            // Dock badge: count of due-today/overdue cards (nil clears it)
            if let count = body["count"] as? Int {
                NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
            }
        default:
            break
        }
    }

    // ---------- Pick up changes that arrived from another device ----------
    // The file presenter reports these as they land; becoming active is the backstop,
    // since a presenter isn't notified while the app is suspended.
    func applicationDidBecomeActive(_ notification: Notification) { syncFromDisk() }

    // Compare by content, not modification date: iCloud can restore a file with an older
    // mtime, and comparing dates also can't tell our own write apart from a foreign one.
    func syncFromDisk() {
        // applicationDidBecomeActive can fire while a startup alert is spinning the run
        // loop, before the web view exists. Without this guard the change is recorded as
        // seen and then applied to nothing.
        guard webView != nil else { return }
        guard let contents = coordinatedRead(DATA_FILE), !contents.isEmpty,
              contents != lastWrittenJSON else { return }
        lastWrittenJSON = contents
        updateLastMod()
        NSLog("Sweckban: applying external change from %@ (%d bytes)", DATA_FILE, contents.utf8.count)
        webView?.evaluateJavaScript(
            "window.__sweckbanApplyExternal && window.__sweckbanApplyExternal(\(jsString(contents)))",
            completionHandler: nil)
    }

    // Adopt the app's iCloud container once it becomes reachable (i.e. once the
    // provisioning profile is in place). Copies rather than moves, and adopts a file
    // already in the container rather than overwriting it — the same rule as Change Location.
    func adoptICloudContainerIfAvailable() {
        guard let docs = iCloudDocumentsDir(), docs != DATA_DIR else { return }
        let fm = FileManager.default
        let containerFile = docs + "/sweckban-data.json"

        if !fm.fileExists(atPath: containerFile), fm.fileExists(atPath: DATA_FILE) {
            let a = NSAlert()
            a.messageText = "Move Sweckban's data to iCloud?"
            a.informativeText = "Your boards would move into Sweckban's own iCloud storage, so they "
                + "sync to your other devices automatically and can't be moved by accident.\n\n"
                + "The current file at\n\(DATA_FILE)\nis left where it is as a backup."
            a.addButton(withTitle: "Move to iCloud")
            // Labelled for what it actually does: declining is remembered, so the app
            // won't re-ask on every launch. Change Location… re-opens the choice.
            a.addButton(withTitle: "Keep Using This Folder")
            guard a.runModal() == .alertFirstButtonReturn else {
                UserDefaults.standard.set(false, forKey: "useICloud")
                return
            }
            guard let text = coordinatedRead(DATA_FILE),
                  (try? coordinatedWrite(text, to: containerFile)) != nil else {
                NSLog("Sweckban: couldn't copy data into the iCloud container; staying local")
                return
            }
        }
        guard fm.fileExists(atPath: containerFile) else { return }
        DATA_DIR = docs
        UserDefaults.standard.set(true, forKey: "useICloud")
        NSLog("Sweckban: using iCloud container at %@", docs)
    }

    func changeLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder where Sweckban keeps sweckban-data.json"
        panel.directoryURL = URL(fileURLWithPath: DATA_DIR)
        guard panel.runModal() == .OK, let url = panel.url, url.path != DATA_DIR else { return }

        let fm = FileManager.default
        let newFile = url.path + "/sweckban-data.json"
        // Carry current data over — unless the destination already has a data
        // file (e.g. pointing this Mac at an iCloud folder the other Mac made),
        // in which case adopt that file rather than clobbering it.
        if fm.fileExists(atPath: DATA_FILE) && !fm.fileExists(atPath: newFile) {
            try? fm.copyItem(atPath: DATA_FILE, toPath: newFile)
        }
        DATA_DIR = url.path
        UserDefaults.standard.set(DATA_DIR, forKey: "dataDir")
        // Picking a folder by hand opts out of the iCloud container, otherwise the next
        // launch would quietly move back to it.
        UserDefaults.standard.set(false, forKey: "useICloud")
        try? fm.createDirectory(atPath: BACKUP_DIR, withIntermediateDirectories: true)
        DataFileWatcher.shared.relocate()
        updateLastMod()

        let contents = coordinatedRead(DATA_FILE) ?? ""
        lastWrittenJSON = contents
        webView.evaluateJavaScript(
            "window.__sweckbanRelocated && window.__sweckbanRelocated(\(jsString(DATA_FILE)), \(jsString(contents)))",
            completionHandler: nil)
    }

    func updateLastMod() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: DATA_FILE),
           let mod = attrs[.modificationDate] as? Date {
            lastMod = mod
        }
    }

    // ---------- JS alert/confirm need a UI delegate in WKWebView ----------
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = "Sweckban"
        a.informativeText = message
        a.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = "Sweckban"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    // ---------- <input type="file"> needs an open-panel delegate in WKWebView ----------
    // Without this, clicking a file input (background image, Import JSON) does nothing.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    // ---------- Menu bar ----------
    // Most items drive the web UI through window.__sweckbanMenu(action).
    func runMenu(_ action: String) {
        webView?.evaluateJavaScript("window.__sweckbanMenu && window.__sweckbanMenu('\(action)')",
                                    completionHandler: nil)
    }
    @objc func menuSettings()       { runMenu("settings") }
    @objc func menuNewBoard()       { runMenu("newBoard") }
    @objc func menuNewPlanner()     { runMenu("newPlanner") }
    @objc func menuNewCard()        { runMenu("newCard") }
    @objc func menuExport()         { runMenu("export") }
    @objc func menuImport()         { runMenu("import") }
    @objc func menuArchive()        { runMenu("archive") }
    @objc func menuToggleTheme()    { runMenu("toggleTheme") }
    @objc func menuToggleSidebar()  { runMenu("toggleSidebar") }
    @objc func menuTogglePeople()   { runMenu("togglePeople") }
    @objc func menuToggleFitWidth() { runMenu("toggleFitWidth") }
    @objc func menuNextBoard()      { runMenu("nextBoard") }
    @objc func menuPrevBoard()      { runMenu("prevBoard") }
    @objc func menuReveal()         { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: DATA_FILE)]) }
    @objc func menuChangeLocation() { changeLocation() }

    // Small helper to add an item with an explicit modifier mask
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String,
                     _ mods: NSEvent.ModifierFlags = .command) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = mods }
        item.target = self
        menu.addItem(item)
    }

    func buildMenu() {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Sweckban",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        add(appMenu, "Settings…", #selector(menuSettings), ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sweckban",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File menu
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        add(file, "New Card", #selector(menuNewCard), "n")
        add(file, "New Board", #selector(menuNewBoard), "n", [.command, .shift])
        add(file, "New Planner", #selector(menuNewPlanner), "n", [.command, .option])
        file.addItem(.separator())
        add(file, "Export JSON…", #selector(menuExport), "e")
        add(file, "Import JSON…", #selector(menuImport), "i")
        file.addItem(.separator())
        add(file, "Archived Cards…", #selector(menuArchive), "")
        file.addItem(.separator())
        add(file, "Reveal Data File in Finder", #selector(menuReveal), "")
        add(file, "Change Data Location…", #selector(menuChangeLocation), "")
        fileItem.submenu = file

        // Edit menu (native text editing — Cmd+Z here is text undo in fields)
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        // View menu
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        add(view, "Toggle Sidebar", #selector(menuToggleSidebar), "s", [.command, .option])
        add(view, "Toggle Light / Dark", #selector(menuToggleTheme), "l", [.command, .option])
        add(view, "Toggle People Section", #selector(menuTogglePeople), "")
        add(view, "Fit Columns to Window", #selector(menuToggleFitWidth), "")
        viewItem.submenu = view

        // Board menu
        let boardItem = NSMenuItem(); main.addItem(boardItem)
        let board = NSMenu(title: "Board")
        add(board, "Next Board", #selector(menuNextBoard), "]", [.command, .shift])
        add(board, "Previous Board", #selector(menuPrevBoard), "[", [.command, .shift])
        boardItem.submenu = board

        NSApp.mainMenu = main
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // On quit, pull the latest state straight from the web view and write it before
    // exiting — closes the race where the last async save() message hadn't been
    // delivered yet. A 2s watchdog guarantees the quit never hangs.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let webView = webView else { return .terminateNow }
        var replied = false
        let finish: (String?) -> Void = { json in
            if replied { return }
            replied = true
            if let json = json, !json.isEmpty { self.writeData(json) }
            DataFileWatcher.shared.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(nil) }
        webView.evaluateJavaScript("window.__sweckbanCurrentState ? window.__sweckbanCurrentState() : ''") { result, _ in
            finish(result as? String)
        }
        return .terminateLater
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
