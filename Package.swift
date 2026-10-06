// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "C2CWorkspaceManager",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "C2CManager", targets: ["C2CManager"])],
    targets: [
        .executableTarget(name: "C2CManager", exclude: ["ConnectionStatusView 2.swift"]),
        .testTarget(name: "C2CManagerTests", dependencies: ["C2CManager"])
    ]
)
