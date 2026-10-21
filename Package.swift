// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BoxSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BoxSyncCore", targets: ["BoxSyncCore"]),
        .executable(name: "BoxSyncApp", targets: ["BoxSyncApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
    ],
    targets: [
        .target(
            name: "BoxSyncCore",
            dependencies: [.product(name: "Citadel", package: "Citadel")]
        ),
        .executableTarget(name: "BoxSyncApp", dependencies: ["BoxSyncCore"]),
        .testTarget(name: "BoxSyncCoreTests", dependencies: ["BoxSyncCore"]),
    ]
)
