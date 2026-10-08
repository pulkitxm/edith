// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EdithExtensions",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "KeepAwakeExtension", path: "keepAwake", exclude: ["Tests"]),
        .testTarget(
            name: "KeepAwakeExtensionTests", dependencies: ["KeepAwakeExtension"],
            path: "keepAwake/Tests"),
    ]
)
