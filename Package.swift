// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IndirectInput",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MX2Feedback", path: "Sources/MX2Feedback"),
        .target(name: "MX2Native", dependencies: ["BridgeCore", "MX2Feedback"], path: "Sources/MX2Native"),
        .target(name: "BridgeCore", path: "Sources/BridgeCore"),
        .executableTarget(
            name: "MX2SyndicateBridge",
            dependencies: ["BridgeCore", "MX2Native", "MX2Feedback"],
            path: "Sources/MX2SyndicateBridge"
        ),
        .executableTarget(
            name: "MX2CLITest",
            dependencies: ["BridgeCore"],
            path: "Sources/MX2CLITest"
        ),
        .testTarget(
            name: "MX2NativeTests",
            dependencies: ["MX2Native"],
            path: "Tests/MX2NativeTests"
        ),
        .testTarget(
            name: "MX2FeedbackTests",
            dependencies: ["MX2Feedback"],
            path: "Tests/MX2FeedbackTests"
        ),
        .testTarget(
            name: "MX2SyndicateBridgeTests",
            dependencies: ["BridgeCore"],
            path: "Tests/MX2SyndicateBridgeTests"
        )
    ]
)
