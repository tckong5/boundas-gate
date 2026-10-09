// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "C2CWorkspaceManager",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "C2CManager", targets: ["C2CManager"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(name: "C2CManager", dependencies: [.product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "C2CManagerTests", dependencies: ["C2CManager"])
    ]
)
