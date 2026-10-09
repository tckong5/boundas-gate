import Foundation
import Darwin

struct AppDataPaths {
    let support: URL
    let newUserTest: Bool
    var overrides: [String: String] = [:]

    var directory: URL {
        support.appendingPathComponent(newUserTest ? "Boundas Gate New User Test" : "Boundas Gate")
    }
    var workspaces: URL { overridden("BOUNDAS_WORKSPACES_FILE", default: directory.appendingPathComponent("workspaces.json")) }
    var gateway: URL { overridden("BOUNDAS_GATEWAY_DIR", default: directory.appendingPathComponent("gateway")) }
    var tailscale: URL { overridden("BOUNDAS_STATE_DIR", default: directory.appendingPathComponent("tailscale")) }
    var c2c: URL {
        overridden("C2C_STATE_DIR", default: newUserTest ? directory.appendingPathComponent("c2c") : support.appendingPathComponent("codex-with-chatgpt"))
    }
    var c2cLogs: URL { c2c.appendingPathComponent("logs") }
    var windowTitle: String { newUserTest ? "Boundas Gate · 新用戶測試" : "Boundas Gate" }

    func childEnvironment(_ inherited: [String: String]) -> [String: String] {
        var environment = inherited
        // The Swift folder store and every Node child must use the same profile.
        // Override inherited paths so the test app cannot reconnect the real Gate.
        environment["BOUNDAS_WORKSPACES_FILE"] = workspaces.path
        environment["BOUNDAS_GATEWAY_DIR"] = gateway.path
        environment["BOUNDAS_STATE_DIR"] = tailscale.path
        environment["C2C_STATE_DIR"] = c2c.path
        return environment
    }

    private func overridden(_ key: String, default fallback: URL) -> URL {
        guard !newUserTest, let value = overrides[key] else { return fallback }
        return URL(fileURLWithPath: value)
    }

    /// Finish migration before creating any store, refresh task or child process.
    func prepare() throws {
        guard !newUserTest else { return }
        let usesCanonical = overrides["BOUNDAS_WORKSPACES_FILE"] == nil
            || overrides["BOUNDAS_GATEWAY_DIR"] == nil || overrides["BOUNDAS_STATE_DIR"] == nil
        if usesCanonical { try ProductStateMigration.prepare(support: support) }
    }

    static var current: AppDataPaths {
        .init(support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
              newUserTest: Bundle.main.object(forInfoDictionaryKey: "BoundasGateDataProfile") as? String == "new-user-test",
              overrides: ProcessInfo.processInfo.environment)
    }
}

/// Publish a complete copy atomically; the legacy directory remains a backup.
/// The lock is deliberately outside both profiles and shared across app launches.
enum ProductStateMigration {
    static func prepare(support: URL, copy: (URL, URL) throws -> Void = {
        try FileManager.default.copyItem(at: $0, to: $1)
    }) throws {
        let fm = FileManager.default
        let destination = support.appendingPathComponent("Boundas Gate")
        let legacy = support.appendingPathComponent("C2C Workspace Manager")
        func exists(_ url: URL) throws -> Bool {
            do {
                let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                guard type == .typeDirectory else { throw MigrationError.invalidDirectory }
                return true
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return false }
        }
        if try exists(destination) { return }
        guard try exists(legacy) else { return }
        let descriptor = open(support.appendingPathComponent(".boundas-profile-migration.lock").path,
                              O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw MigrationError.failed }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw MigrationError.busy }
        defer { flock(descriptor, LOCK_UN) }
        if try exists(destination) { return }
        let staging = support.appendingPathComponent(".boundas-migration-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        do {
            let before = try snapshot(legacy, checkRuntime: true)
            try copy(legacy, staging)
            guard before == (try snapshot(staging, checkRuntime: false)),
                  before == (try snapshot(legacy, checkRuntime: true)) else { throw MigrationError.changed }
            // RENAME_EXCL never replaces another independently created profile.
            guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST, try exists(destination) { return }
                throw MigrationError.failed
            }
        } catch let error as MigrationError { throw error }
        catch { throw MigrationError.failed }
    }

    private struct Entry: Equatable {
        let contents: Data?
        let permissions: UInt16
        let directory: Bool
    }
    private static func snapshot(_ root: URL, checkRuntime: Bool) throws -> [String: Entry] {
        let fm = FileManager.default
        let root = root.resolvingSymlinksInPath()
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, error in enumerationError = error; return false }) else { throw MigrationError.failed }
        var entries: [String: Entry] = [:]
        let urls: [(URL, String)] = [(root, "")] + enumerator.compactMap {
            guard let url = $0 as? URL else { return nil }
            return (url, url.pathComponents.suffix(enumerator.level).joined(separator: "/"))
        }
        if enumerationError != nil { throw MigrationError.failed }
        for (url, relativePath) in urls {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular else { throw MigrationError.invalidDirectory }
            let data = type == .typeRegular ? try Data(contentsOf: url) : nil
            if checkRuntime, url.lastPathComponent == "runtime.json", let data,
               let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = record["pid"] as? Int, pid > 0, pid <= Int(Int32.max),
               kill(pid_t(pid), 0) == 0 || errno != ESRCH { throw MigrationError.running }
            entries[relativePath] = Entry(contents: data,
                permissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
                directory: type == .typeDirectory)
        }
        return entries
    }

    enum MigrationError: LocalizedError {
        case failed, busy, running, changed, invalidDirectory
        var errorDescription: String? {
            switch self {
            case .running: return "Please close the Gate in the previous app before migrating. Your existing data has been preserved."
            case .busy: return "Another Boundas Gate app is migrating your data. Close it and reopen this app."
            default: return "Boundas Gate couldn't migrate your existing data. No new Gate was started. Your legacy data has been preserved."
            }
        }
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
