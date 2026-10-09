// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CameraDeployment", platforms: [.macOS(.v14)],
    products: [.library(name: "CameraDeployment", targets: ["CameraDeployment"])],
    targets: [
        .target(name: "CameraDeployment", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "CameraDeploymentTests", dependencies: ["CameraDeployment"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
