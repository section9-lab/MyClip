// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyClipCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "MyClipCore", targets: ["MyClipCore"]), .executable(name: "myclip-mcp", targets: ["MyClipMCP"])],
    targets: [
        .target(name: "MyClipCore", path: "MyClip/Core"),
        .executableTarget(name: "MyClipMCP", dependencies: ["MyClipCore"], path: "Sources/MyClipMCP"),
        .testTarget(name: "MyClipCoreTests", dependencies: ["MyClipCore"], path: "Tests/MyClipCoreTests", resources: [.copy("Fixtures")])
    ]
)
