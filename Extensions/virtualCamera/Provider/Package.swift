// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "CameraProvider", platforms: [.macOS(.v14)],
    products: [.library(name: "CameraProvider", type: .dynamic, targets: ["CameraProvider"])],
    targets: [
        .target(name: "CameraProvider", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "CameraProviderTests", dependencies: ["CameraProvider"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
