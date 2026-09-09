// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotBridgeMenuBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CopilotBridgeMenuBar", targets: ["BridgeMenuBar"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "BridgeCore", dependencies: ["CSQLite"]),
        .target(name: "BridgeRuntime", dependencies: ["BridgeCore"]),
        .target(name: "BridgeUI", dependencies: ["BridgeCore", "BridgeRuntime"]),
        .executableTarget(name: "BridgeMenuBar", dependencies: ["BridgeUI", "BridgeRuntime"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore", "CSQLite"]),
        .testTarget(name: "BridgeRuntimeTests", dependencies: ["BridgeRuntime", "BridgeCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "BridgeUITests", dependencies: ["BridgeUI", "BridgeRuntime", "BridgeCore", "CSQLite"])
    ],
    swiftLanguageModes: [.v5]
)
