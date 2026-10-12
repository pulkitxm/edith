// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HostedFunctionalActions",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FunctionalActionContract", targets: ["FunctionalActionContract"])],
    dependencies: [
        .package(path: "../../Extensions/fixtureSupport"),
        .package(path: "../../Packages/ExtensionMarketplace"),
    ],
    targets: [
        .target(
            name: "FunctionalActionContract",
            dependencies: [.product(name: "WorkerFixtureSupport", package: "fixtureSupport")]),
        .target(
            name: "FunctionalProducerModels",
            dependencies: [
                "FunctionalActionContract",
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
                .product(name: "ExtensionMarketplace", package: "ExtensionMarketplace"),
            ],
            path: "ProducerSources",
            exclude: [
                "FunctionalProducer.swift", "FunctionalOriginalUI.swift",
                "FunctionalSignatureProbe.swift", "FunctionalRequestJournal.swift",
                "FunctionalProducerReceiver.swift",
            ],
            sources: [
                "FunctionalIssuer.swift", "FunctionalLifecycle.swift",
                "FunctionalPersistence.swift", "FunctionalFileScopes.swift",
                "FunctionalCollectedEvidence.swift", "FunctionalEvidenceAssembly.swift",
                "FunctionalEvidenceSealing.swift",
            ]),
        .testTarget(
            name: "FunctionalProducerModelTests",
            dependencies: [
                "FunctionalProducerModels",
                .product(name: "WorkerFixtureSupport", package: "fixtureSupport"),
            ]),
        .testTarget(
            name: "FunctionalActionContractTests", dependencies: ["FunctionalActionContract"]),
    ]
)
