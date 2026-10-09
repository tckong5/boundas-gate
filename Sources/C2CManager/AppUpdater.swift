import SwiftUI
import Sparkle

/// Production only reads the signed bundle configuration; development profiles
/// cannot inherit the production feed or update the production application.
enum UpdateConfiguration {
    static let publicKey = "ATH06nujvadK3M79ihD6vc8A8b0nCsEzCf+VBP9a2TU="

    static func feed(info: [String: Any], profile: AppDataPaths.Profile) -> URL? {
        guard let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
        let field = profile == .production ? "SUFeedURL" : "BoundasGateTestFeedURL"
        guard let value = info[field] as? String, let url = URL(string: value),
              let host = url.host, url.user == nil, url.password == nil,
              url.fragment == nil else { return nil }
        if profile == .production {
            guard url.scheme == "https", !["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) else { return nil }
        } else {
            guard url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())) else { return nil }
        }
        return url
    }
}

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController?
    private var feedURL: URL?

    override init() {
        super.init()
        // Raw executables are not installable app bundles.
        guard Bundle.main.bundleURL.pathExtension == "app",
              let feed = UpdateConfiguration.feed(info: Bundle.main.infoDictionary ?? [:], profile: AppDataPaths.current.profile) else { return }
        feedURL = feed
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.startUpdater()
    }

    func feedURLString(for updater: SPUUpdater) -> String? { feedURL?.absoluteString }
    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updates: AppUpdater
    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)
    }
}
