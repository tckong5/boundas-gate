import Foundation

struct AppDataPaths {
    let support: URL
    let newUserTest: Bool

    var directory: URL {
        support.appendingPathComponent(newUserTest ? "Boundas Gate New User Test" : "C2C Workspace Manager")
    }
    var workspaces: URL { directory.appendingPathComponent("workspaces.json") }
    var gateway: URL { directory.appendingPathComponent("gateway") }
    var c2c: URL {
        newUserTest ? directory.appendingPathComponent("c2c") : support.appendingPathComponent("codex-with-chatgpt")
    }
    var c2cLogs: URL { c2c.appendingPathComponent("logs") }
    var windowTitle: String { newUserTest ? "Boundas Gate · 新用戶測試" : "Boundas Gate" }

    func childEnvironment(_ inherited: [String: String]) -> [String: String] {
        guard newUserTest else { return inherited }
        var environment = inherited
        // The Swift folder store and every Node child must use the same profile.
        // Override inherited paths so the test app cannot reconnect the real Gate.
        environment["BOUNDAS_WORKSPACES_FILE"] = workspaces.path
        environment["BOUNDAS_GATEWAY_DIR"] = gateway.path
        environment["BOUNDAS_STATE_DIR"] = directory.appendingPathComponent("tailscale").path
        environment["C2C_STATE_DIR"] = c2c.path
        return environment
    }

    static var current: AppDataPaths {
        .init(support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
              newUserTest: Bundle.main.object(forInfoDictionaryKey: "BoundasGateDataProfile") as? String == "new-user-test")
    }
}

struct RuntimePaths {
    let resources: URL?
    let home: URL
    var applicationBundle = false
    var bundled: Bool { applicationBundle || resources?.path.contains(".app/Contents/Resources") == true
        || (resources.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Runtime").path) } ?? false) }
    var cli: String {
        if bundled {
            let root = resources ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
            return root.appendingPathComponent("Runtime/C2C/bin/c2c.js").path
        }
        return home.appendingPathComponent("codex-with-chatgpt/bin/c2c.js").path
    }
    var backend: String { URL(fileURLWithPath: cli).deletingLastPathComponent().deletingLastPathComponent().path }
    var bundledNode: String? {
        guard let resources else { return nil }
        let file = resources.appendingPathComponent("Runtime/bin/node").path
        return FileManager.default.isExecutableFile(atPath: file) ? file : nil
    }
    var cloudflared: String? {
        guard let resources else { return nil }
        let file = resources.appendingPathComponent("Runtime/bin/cloudflared").path
        return FileManager.default.isExecutableFile(atPath: file) ? file : nil
    }
    func resource(_ relative: String, developerRoot: URL? = nil) throws -> URL {
        if let resources {
            let file = resources.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        #if DEBUG
        if !bundled, let developerRoot {
            let file = developerRoot.appendingPathComponent("Resources").appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        #endif
        throw RuntimeResourceError.missing(relative)
    }
    static var current: RuntimePaths { .init(resources: Bundle.main.resourceURL, home: FileManager.default.homeDirectoryForCurrentUser,
                                            applicationBundle: Bundle.main.bundleURL.pathExtension == "app") }
}

enum RuntimeResourceError: LocalizedError {
    case missing(String)
    var errorDescription: String? {
        switch self { case .missing(let resource): return "安裝包缺少 \(resource)，請重新安裝 Boundas Gate。" }
    }
}
