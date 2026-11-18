// swift-tools-version: 6.0
import PackageDescription

// Module names describe the *protocol*, not the product: the app is Indirect Input, but
// MX2Native and MX2Feedback are about the Traktor MX2 and its RGB feedback, so renaming
// them would cost every import and buy nothing.
let package = Package(
    name: "IndirectInput",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MX2Feedback", path: "Sources/MX2Feedback"),
        .target(name: "MX2Native", dependencies: ["IndirectInputCore", "MX2Feedback"], path: "Sources/MX2Native"),
        .target(name: "IndirectInputCore", path: "Sources/IndirectInputCore"),
        .executableTarget(
            name: "IndirectInputApp",
            dependencies: ["IndirectInputCore", "MX2Native", "MX2Feedback"],
            path: "Sources/IndirectInputApp"
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
            name: "IndirectInputAppTests",
            dependencies: ["IndirectInputCore"],
            path: "Tests/IndirectInputAppTests"
        )
    ]
)
