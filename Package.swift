// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Nib",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Nib",
            path: "Sources/Nib"
        )
    ]
)
