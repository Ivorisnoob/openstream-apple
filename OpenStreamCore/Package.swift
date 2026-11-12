// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenStreamCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "OpenStreamCore", targets: ["OpenStreamCore"]),
    ],
    targets: [
        .target(
            name: "OpenStreamCore",
            resources: [.copy("Resources/catalog.json")]
        ),
        .testTarget(
            name: "OpenStreamCoreTests",
            dependencies: ["OpenStreamCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
