// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnkiFlow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AnkiFlow",
            path: "Sources/AnkiFlow"
        )
    ]
)
