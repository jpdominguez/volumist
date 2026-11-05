// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Volumist",
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "CMixer"),
        .executableTarget(name: "Volumist", dependencies: ["CMixer"]),
    ]
)
