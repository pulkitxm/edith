// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MeetingVoice",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MeetingVoice", type: .dynamic, targets: ["MeetingVoiceRuntime"])],
    dependencies: [
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git",
            revision: "b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2")
    ],
    targets: [
        .target(
            name: "MeetingVoiceRuntime",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
            ],
            linkerSettings: [
                .linkedLibrary("c++"), .linkedLibrary("objc"),
                .linkedFramework("Foundation"), .linkedFramework("CoreML"),
                .linkedFramework("Accelerate"),
            ])
    ],
    cxxLanguageStandard: .cxx17
)
