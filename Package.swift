// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cc-status-light",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "cc-status-light",
            path: "Sources/cc-status-light",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
