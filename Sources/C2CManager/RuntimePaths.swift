import Foundation

struct RuntimePaths {
    let resources: URL?
    let home: URL
    var bundled: Bool { resources.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Runtime").path) } ?? false }
    var cli: String {
        if bundled, let resources { return resources.appendingPathComponent("Runtime/C2C/bin/c2c.js").path }
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
    static var current: RuntimePaths { .init(resources: Bundle.main.resourceURL, home: FileManager.default.homeDirectoryForCurrentUser) }
}
