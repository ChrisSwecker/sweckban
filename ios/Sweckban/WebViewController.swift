import UIKit
import WebKit
import UserNotifications

// ============================================================
// The shell: hosts sweckban.html and is the other half of its bridge
// ============================================================
// Same handler name, same injected globals and same commands as the Mac app, so the page
// can't tell the difference beyond __SWECKBAN_PLATFORM.

final class WebViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {

    private let fileURL: URL          // the data file
    private let bootContents: String?
    private let synced: Bool          // is the file actually in the iCloud container?
    private var webView: WKWebView!
    private var appURL: URL?          // the bundled sweckban.html — the only page ever allowed
    private var lastWrittenJSON = ""  // so a sync-in is distinguishable from our own write
    private var bridgeLogged = false
    private var saveErrorShown = false
    private var badgeAsked = false

    init(fileURL: URL, bootContents: String?, synced: Bool) {
        self.fileURL = fileURL
        self.bootContents = bootContents
        self.synced = synced
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)

        let config = WKWebViewConfiguration()
        let ucc = config.userContentController
        ucc.add(self, name: "sweckban")

        var boot = "window.__SWECKBAN_NATIVE = true; window.__SWECKBAN_PLATFORM = \"ios\";"
                 + " window.__SWECKBAN_SYNCED = \(synced ? "true" : "false");"
                 + " window.__SWECKBAN_DATA_PATH = \(jsString(fileURL.path));"
        if let contents = bootContents, !contents.isEmpty {
            lastWrittenJSON = contents
            boot += "window.__SWECKBAN_BOOT_DATA = \(jsString(contents));"
        }
        ucc.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // The page owns its own safe areas (via env(safe-area-inset-*)), so keep UIKit out of it.
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = view.backgroundColor
        view.addSubview(webView)

        if let url = Bundle.main.url(forResource: "sweckban", withExtension: "html") {
            appURL = url
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            NSLog("Sweckban: sweckban.html is missing from the bundle")
        }

        DataFileWatcher.shared.onChange = { [weak self] in
            self?.syncFromDisk()
            self?.resolveConflicts()   // after the sync: merge the winner first, then the losers
        }
        DataFileWatcher.shared.start(fileURL)
    }

    // ---------- Navigation lockdown ----------
    // Only the bundled page may ever be shown. Left alone, WKWebView will navigate to any
    // link tapped inside it — and that page would inherit the `sweckban` message handler,
    // i.e. the ability to overwrite the data file.
    private func isAppPage(_ url: URL?) -> Bool {
        guard let url = url, let app = appURL, url.isFileURL else { return false }
        return url.standardizedFileURL.path == app.standardizedFileURL.path
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if isAppPage(url) { decisionHandler(.allow); return }
        if let url = url, ["http", "https"].contains(url.scheme ?? "") {
            UIApplication.shared.open(url)
        }
        NSLog("Sweckban: blocked navigation to %@", url?.absoluteString ?? "(nil)")
        decisionHandler(.cancel)
    }

    // The page has to be loaded before it can be handed anything, so the launch pass over
    // conflict versions waits for it.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resolveConflicts()
    }

    // ---------- JS -> native ----------
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "sweckban" else { return }
        // Accept messages only from our own page, in the main frame.
        guard message.frameInfo.isMainFrame, isAppPage(message.frameInfo.request.url) else {
            NSLog("Sweckban: ignored bridge message from %@",
                  message.frameInfo.request.url?.absoluteString ?? "(nil)")
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
            if let data = body["data"] as? String { writeData(data) }
        case "badge":
            if let count = body["count"] as? Int { setBadge(count) }
        case "export":
            if let data = body["data"] as? String {
                exportJSON(data, name: (body["name"] as? String) ?? "sweckban-backup.json")
            }
        case "revealData", "changeLocation":
            // macOS-only affordances. The page hides them on iOS; ignore them if they arrive.
            break
        default:
            break
        }
    }

    @discardableResult
    func writeData(_ data: String) -> Bool {
        do {
            try coordinatedWrite(data, to: fileURL)
            lastWrittenJSON = data
            saveErrorShown = false
            return true
        } catch {
            NSLog("Sweckban: write to %@ failed: %@", fileURL.path, String(describing: error))
            if !saveErrorShown {
                saveErrorShown = true
                let a = UIAlertController(
                    title: "Sweckban couldn't save your changes",
                    message: "Writing to\n\(fileURL.lastPathComponent)\nfailed: \(error.localizedDescription)\n\n"
                           + "Your recent changes are NOT on disk. Use Export JSON in Settings to save a copy now.",
                    preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "OK", style: .default))
                present(a, animated: true)
            }
            return false
        }
    }

    // ---------- Pick up changes that arrived from another device ----------
    // Compare by content, not modification date: iCloud can restore a file with an older
    // mtime, and dates can't tell our own write apart from a foreign one.
    func syncFromDisk() {
        guard webView != nil else { return }
        guard let contents = coordinatedRead(fileURL), !contents.isEmpty,
              contents != lastWrittenJSON else { return }
        lastWrittenJSON = contents
        NSLog("Sweckban: applying external change from %@ (%d bytes)", fileURL.path, contents.utf8.count)
        applyExternalJSON(contents)
    }

    func applyExternalJSON(_ json: String) {
        webView?.evaluateJavaScript(
            "window.__sweckbanApplyExternal && window.__sweckbanApplyExternal(\(jsString(json)))",
            completionHandler: nil)
    }

    // ---------- iCloud conflict versions ----------
    // When two devices write the file while offline, iCloud doesn't merge: it picks a
    // winner and parks the loser as an unresolved NSFileVersion. Feed each through the same
    // merge the sync path uses — it is commutative and idempotent, so order doesn't matter
    // — then clear them.
    func resolveConflicts() {
        guard webView != nil else { return }
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL),
              !versions.isEmpty else { return }
        NSLog("Sweckban: resolving %d conflict version(s) of %@", versions.count, fileURL.path)

        for v in versions {
            if let text = try? String(contentsOf: v.url, encoding: .utf8), !text.isEmpty {
                applyExternalJSON(text)
            } else {
                NSLog("Sweckban: couldn't read conflict version at %@", v.url.path)
            }
            v.isResolved = true
        }

        var coordError: NSError?
        NSFileCoordinator(filePresenter: DataFileWatcher.shared)
            .coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordError) { u in
                do { try NSFileVersion.removeOtherVersionsOfItem(at: u) }
                catch { NSLog("Sweckban: couldn't remove conflict versions: %@", String(describing: error)) }
            }
        if let e = coordError {
            NSLog("Sweckban: conflict cleanup coordination failed: %@", String(describing: e))
        }
    }

    // ---------- Background flush ----------
    // iOS has no quit. Pull the latest state and write it before the app suspends, which
    // closes the race where the last async save() hadn't been delivered yet.
    func flush() {
        guard let webView = webView else { return }
        let sema = DispatchSemaphore(value: 0)
        var json: String?
        webView.evaluateJavaScript("window.__sweckbanCurrentState ? window.__sweckbanCurrentState() : ''") { result, _ in
            json = result as? String
            sema.signal()
        }
        // evaluateJavaScript calls back on the main queue, so we can't block it. Spin the
        // run loop instead, with a short cap so backgrounding is never held up.
        let deadline = Date().addingTimeInterval(1.5)
        while sema.wait(timeout: .now()) == .timedOut && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if let json = json, !json.isEmpty {
            NSLog("Sweckban: flushing %d bytes before suspend", json.utf8.count)
            writeData(json)
        }
    }

    // ---------- Badge ----------
    private func setBadge(_ count: Int) {
        let apply = {
            UNUserNotificationCenter.current().setBadgeCount(count) { err in
                if let err = err { NSLog("Sweckban: badge failed: %@", String(describing: err)) }
            }
        }
        if badgeAsked { apply(); return }
        badgeAsked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { granted, _ in
            guard granted else { return }   // denied: silently skip, the app is unaffected
            DispatchQueue.main.async { apply() }
        }
    }

    // ---------- Export ----------
    private func exportJSON(_ data: String, name: String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: tmp, atomically: true, encoding: .utf8) }
        catch {
            NSLog("Sweckban: couldn't stage the export: %@", String(describing: error))
            return
        }
        let sheet = UIActivityViewController(activityItems: [tmp], applicationActivities: nil)
        // iPad refuses to present an activity sheet without an anchor.
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    // ---------- JS alert / confirm need a UI delegate in WKWebView ----------
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: "Sweckban", message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: "Sweckban", message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }
}
