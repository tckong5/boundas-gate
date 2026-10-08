import Foundation

/// Presentation context only. Gate identity and authorization remain server-owned.
struct GateUIContext {
    let folder: WorkspaceRecord?
    static let main = GateUIContext(folder: nil)
    static func side(_ folder: WorkspaceRecord) -> Self { .init(folder: folder) }
    var isSide: Bool { folder != nil }
    var title: String { isSide ? "Side Gate" : "Main Gate" }
    var localTitle: String { isSide ? "Side Gate" : "Boundas Gate" }
    var setupTitle: String { isSide ? "Finish setting up this Side Gate" : "Finish setting up your Gate" }
    var localInstruction: String { isSide ? "Start the local MCP host for this Folder." : "Start the local MCP host on this Mac." }
    var appName: String { folder.map { "Boundas Gate · \($0.name)" } ?? "Boundas Gate" }
    var appDescription: String { folder.map { "Access only \($0.name) through its Side Gate." } ?? "Access folders shared through Boundas Gate." }
    func setupFile(in directory: URL = AppDataPaths.current.directory) -> URL {
        if let folder { return directory.appendingPathComponent("side-ai-setup").appendingPathComponent("\(folder.c2cID).json") }
        return directory.appendingPathComponent("ai-setup.json")
    }
}
