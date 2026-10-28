// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DiskClean",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "DiskClean",
            path: "Sources/DiskClean",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
