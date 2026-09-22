import Foundation

// ============================================================
// Where the data lives, and how it is read and written
// ============================================================
// Ported from the Mac app's main.swift. Everything here is plain Foundation and behaves
// identically on both platforms — deliberately so: one mental model, one set of bugs.
//
// The one real difference is that resolving the ubiquity container can block for seconds
// on iOS, so it happens off the main thread (see Boot.resolve).

let ICLOUD_CONTAINER_ID = "iCloud.com.swecker.sweckban"
let DATA_FILE_NAME = "sweckban-data.json"

func jsString(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [s])
    var str = String(data: data, encoding: .utf8)!
    str.removeFirst() // strip [
    str.removeLast()  // strip ]
    return str
}

// ---------- Watching the file ----------
// Our own writes pass this presenter to the coordinator, so they don't echo back.
final class DataFileWatcher: NSObject, NSFilePresenter {
    static let shared = DataFileWatcher()
    var onChange: (() -> Void)?

    private var url = URL(fileURLWithPath: "/dev/null")
    private var watching = false
    private let queue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q
    }()

    var presentedItemURL: URL? { url }
    var presentedItemOperationQueue: OperationQueue { queue }

    func start(_ u: URL) {
        if watching { stop() }
        url = u
        NSFileCoordinator.addFilePresenter(self)
        watching = true
        NSLog("Sweckban: watching %@", u.path)
    }
    func stop() {
        guard watching else { return }
        NSFileCoordinator.removeFilePresenter(self)
        watching = false
    }

    func presentedItemDidChange() { DispatchQueue.main.async { self.onChange?() } }
    func presentedSubitemDidChange(at url: URL) { presentedItemDidChange() }

    // iCloud kept a second version because two devices wrote while offline. Same handler:
    // the change path resolves conflicts right after it syncs.
    func presentedItemDidGain(_ version: NSFileVersion) {
        NSLog("Sweckban: gained conflict version %@", version.url.lastPathComponent)
        DispatchQueue.main.async { self.onChange?() }
    }
}

func coordinatedRead(_ url: URL) -> String? {
    var text: String?
    var coordError: NSError?
    NSFileCoordinator(filePresenter: DataFileWatcher.shared)
        .coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            text = try? String(contentsOf: u, encoding: .utf8)
        }
    return text
}

func coordinatedWrite(_ text: String, to url: URL) throws {
    var writeError: Error?
    var coordError: NSError?
    NSFileCoordinator(filePresenter: DataFileWatcher.shared)
        .coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do { try text.write(to: u, atomically: true, encoding: .utf8) }
            catch { writeError = error }
        }
    if let e = writeError { throw e }
    if let e = coordError { throw e }
}

// An iCloud file that hasn't downloaded yet reads as nil, which is indistinguishable from
// a corrupt one — and we refuse to boot on an unreadable file, so ask for it and wait.
// Already-present files return immediately, so this is free in the normal case.
func ensureDownloaded(_ url: URL) {
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
        Thread.sleep(forTimeInterval: 0.15)
        if current() { return }
    }
    NSLog("Sweckban: timed out waiting for iCloud to download %@", url.path)
}

// ---------- First launch ----------
// The states the app can start in, in the order they are checked.
enum Boot {
    /// The file is there but unreadable. Booting with an empty board would make the first
    /// save overwrite real data, so we refuse — the same rule as the Mac app.
    case unreadable(URL, String)
    /// Ready to show the page. `contents` is nil when there is no file yet (a Mac hasn't
    /// synced one over): the page seeds itself and the merge reconciles when one arrives.
    case ready(url: URL, contents: String?, synced: Bool)

    /// Call OFF the main thread: url(forUbiquityContainerIdentifier:) can block for
    /// seconds on iOS, unlike on the Mac.
    static func resolve() -> Boot {
        let fm = FileManager.default
        var dir: URL
        var synced = true

        if let container = fm.url(forUbiquityContainerIdentifier: ICLOUD_CONTAINER_ID) {
            dir = container.appendingPathComponent("Documents")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            NSLog("Sweckban: using iCloud container at %@", dir.path)
        } else {
            // No container: not signed into iCloud, iCloud Drive off, or a simulator being
            // a simulator. Keep working locally rather than refusing to launch — everything
            // except sync behaves the same.
            dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            synced = false
            NSLog("Sweckban: no iCloud container; falling back to %@", dir.path)
        }

        let file = dir.appendingPathComponent(DATA_FILE_NAME)
        guard fm.fileExists(atPath: file.path) else {
            return .ready(url: file, contents: nil, synced: synced)
        }
        ensureDownloaded(file)
        guard let contents = coordinatedRead(file) else {
            return .unreadable(file, "Sweckban couldn't read its data file.")
        }
        return .ready(url: file, contents: contents.isEmpty ? nil : contents, synced: synced)
    }
}
