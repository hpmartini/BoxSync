// swift-tools-version:6.0
import PackageDescription

// The core library and its tests. The app and the File Provider extension are built with Xcode (project.yml).
let package = Package(
    name: "BoxSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BoxSyncCore", targets: ["BoxSyncCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
    ],
    targets: [
        .target(
            name: "BoxSyncCore",
            dependencies: [.product(name: "Citadel", package: "Citadel")]
        ),
        .testTarget(name: "BoxSyncCoreTests", dependencies: ["BoxSyncCore"]),
    ]
)
