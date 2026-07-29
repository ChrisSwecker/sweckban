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

class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKUIDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var lastMod: Date = .distantPast
    var saveErrorShown = false   // one-shot guard so a failing disk doesn't spam alerts

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: DATA_DIR, withIntermediateDirectories: true)

        // One-time migration from the old Swecko layout
        let oldFile = ("~/Desktop/Swecko/swecko-data.json" as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: DATA_FILE),
           FileManager.default.fileExists(atPath: oldFile) {
            try? FileManager.default.copyItem(atPath: oldFile, toPath: DATA_FILE)
        }

        let config = WKWebViewConfiguration()
        let ucc = config.userContentController
        ucc.add(self, name: "sweckban")

        // Inject native flag, data path, and current file contents before the page runs
        var boot = "window.__SWECKBAN_NATIVE = true; window.__SWECKBAN_DATA_PATH = \(jsString(DATA_FILE));"
        if let contents = try? String(contentsOfFile: DATA_FILE, encoding: .utf8), !contents.isEmpty {
            boot += "window.__SWECKBAN_BOOT_DATA = \(jsString(contents));"
        }
        ucc.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self

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
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        updateLastMod()
        buildMenu()
    }

    // Write the data file (atomic), backing up first. Surfaces a one-time alert if the
    // write fails instead of failing silently. Returns whether the write succeeded.
    @discardableResult
    func writeData(_ data: String) -> Bool {
        maybeBackup()
        do {
            try data.write(toFile: DATA_FILE, atomically: true, encoding: .utf8)
            updateLastMod()
            saveErrorShown = false
            return true
        } catch {
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
        guard message.name == "sweckban",
              let body = message.body as? [String: Any],
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

    // ---------- Pick up iCloud-synced changes on focus ----------
    func applicationDidBecomeActive(_ notification: Notification) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: DATA_FILE),
              let mod = attrs[.modificationDate] as? Date, mod > lastMod,
              let contents = try? String(contentsOfFile: DATA_FILE, encoding: .utf8),
              !contents.isEmpty else { return }
        lastMod = mod
        webView?.evaluateJavaScript(
            "window.__sweckbanApplyExternal && window.__sweckbanApplyExternal(\(jsString(contents)))",
            completionHandler: nil)
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
        try? fm.createDirectory(atPath: BACKUP_DIR, withIntermediateDirectories: true)
        updateLastMod()

        let contents = (try? String(contentsOfFile: DATA_FILE, encoding: .utf8)) ?? ""
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
