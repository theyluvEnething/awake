// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "awake",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(name: "awake", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "awakeTests", dependencies: ["awake"]),
    ]
)
