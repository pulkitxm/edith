// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EdithDocsWorker",
    platforms: [.macOS(.v14)],
    products: [.library(name: "EdithDocsWorker", type: .dynamic, targets: ["EdithDocsWorker"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")
    ],
    targets: [
        .target(
            name: "EdithDocsWorker",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            resources: [.copy("Resources/cli-docs.json")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "EdithDocsWorkerTests", dependencies: ["EdithDocsWorker"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
