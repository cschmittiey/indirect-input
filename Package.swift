// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IndirectInput",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BridgeCore", path: "Sources/BridgeCore"),
        .executableTarget(
            name: "MX2SyndicateBridge",
            dependencies: ["BridgeCore"],
            path: "Sources/MX2SyndicateBridge"
        ),
        .executableTarget(
            name: "MX2CLITest",
            dependencies: ["BridgeCore"],
            path: "Sources/MX2CLITest"
        ),
        .testTarget(
            name: "MX2SyndicateBridgeTests",
            dependencies: ["BridgeCore"],
            path: "Tests/MX2SyndicateBridgeTests"
        )
    ]
)
