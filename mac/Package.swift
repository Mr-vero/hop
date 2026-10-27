// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Hop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Hop", path: "Sources/Hop"),
    ]
)
