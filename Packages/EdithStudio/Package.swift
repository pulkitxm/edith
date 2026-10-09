// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EdithStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EdithStudio", targets: ["EdithStudio"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19")
    ],
    targets: [
        .target(
            name: "EdithStudio",
            dependencies: ["CPDFium", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            resources: [.copy("Resources/PDFium-Licenses.txt")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "CPDFium", dependencies: ["PDFium"]),
        .binaryTarget(
            name: "PDFium",
            url:
                "https://github.com/espresso3389/pdfium-xcframework/releases/download/v144.0.7811.0-20260502-190206/PDFium-chromium-7811-20260502-190206.xcframework.zip",
            checksum: "948d9257f53f01cbed74b81bb8adc8758e52ac9390751772de7889026d32d5a1"
        ),
        .testTarget(
            name: "EdithStudioTests",
            dependencies: ["EdithStudio"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
