// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "awake",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "awake"),
        .testTarget(name: "awakeTests", dependencies: ["awake"]),
    ]
)
