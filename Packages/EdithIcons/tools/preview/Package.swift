// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "preview",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "preview", dependencies: ["EdithIcons"], swiftSettings: [.swiftLanguageMode(.v5)])]
)
