// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SEOAuditExtension", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/ExtensionSupport")],
    targets: [
        .target(
            name: "SEOAuditExtension",
            dependencies: [.product(name: "EdithExtensionCommands", package: "ExtensionSupport")],
            path: ".", exclude: ["Tests"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "SEOAuditExtensionTests", dependencies: ["SEOAuditExtension"], path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
