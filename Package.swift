// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotBridgeMenuBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CopilotBridgeMenuBar", targets: ["BridgeMenuBar"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "BridgeCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "BridgeMenuBar", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"])
    ],
    swiftLanguageModes: [.v5]
)
