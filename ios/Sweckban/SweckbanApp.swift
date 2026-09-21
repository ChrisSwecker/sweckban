import SwiftUI
import UIKit

// ============================================================
// App entry point and the first-launch states
// ============================================================

@main
struct SweckbanApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = BootModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .ignoresSafeArea()          // the page lays out its own safe areas
                .preferredColorScheme(.dark)
                .task { model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // A file presenter isn't notified while the app is suspended, so coming
                // back to the foreground is the backstop for anything that landed
                // meanwhile — the same role applicationDidBecomeActive plays on the Mac.
                model.host?.syncFromDisk()
                model.host?.resolveConflicts()
            default:
                // iOS has no quit, so backgrounding is where the flush has to happen.
                model.host?.flush()
            }
        }
    }
}

@MainActor
final class BootModel: ObservableObject {
    enum Phase {
        case resolving
        case ready(url: URL, contents: String?, synced: Bool)
        case failed(String, String)   // title, detail
    }
    @Published var phase: Phase = .resolving
    /// Set once the web view exists, so the scene-phase flush can reach it.
    var host: WebViewController?

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        // Resolving the ubiquity container can block for seconds on iOS.
        Task.detached(priority: .userInitiated) {
            let boot = Boot.resolve()
            await MainActor.run {
                switch boot {
                case .unreadable(let url, let msg):
                    self.phase = .failed(msg,
                        "\(url.lastPathComponent)\n\nSweckban opened read-only rather than start with an "
                      + "empty board and overwrite it. Check the file in iCloud Drive, or restore it from "
                      + "a backup on your Mac, then reopen Sweckban.")
                case .ready(let url, let contents, let synced):
                    self.phase = .ready(url: url, contents: contents, synced: synced)
                }
            }
        }
    }
}

struct RootView: View {
    @ObservedObject var model: BootModel

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.08).ignoresSafeArea()
            switch model.phase {
            case .resolving:
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Opening your boards…")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .failed(let title, let detail):
                VStack(spacing: 12) {
                    Text(title).font(.headline).multilineTextAlignment(.center)
                    Text(detail)
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            case .ready(let url, let contents, let synced):
                WebHost(fileURL: url, contents: contents, synced: synced) { model.host = $0 }
                    .ignoresSafeArea()
            }
        }
    }
}

struct WebHost: UIViewControllerRepresentable {
    let fileURL: URL
    let contents: String?
    let synced: Bool
    let onMake: (WebViewController) -> Void

    func makeUIViewController(context: Context) -> WebViewController {
        let vc = WebViewController(fileURL: fileURL, bootContents: contents, synced: synced)
        onMake(vc)
        return vc
    }
    func updateUIViewController(_ vc: WebViewController, context: Context) {}
}
