// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HostedFunctionalActions",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FunctionalActionContract", targets: ["FunctionalActionContract"])],
    dependencies: [.package(path: "../../Extensions/fixtureSupport")],
    targets: [
        .target(
            name: "FunctionalActionContract",
            dependencies: [.product(name: "WorkerFixtureSupport", package: "fixtureSupport")]),
        .target(name: "FunctionalProducerModels",
            dependencies: [.product(name: "WorkerFixtureSupport", package: "fixtureSupport")],
            path: "ProducerSources",
            exclude: ["FunctionalProducer.swift", "FunctionalOriginalUI.swift", "FunctionalSignatureProbe.swift", "FunctionalRequestJournal.swift", "FunctionalProducerReceiver.swift"],
            sources: ["FunctionalIssuer.swift", "FunctionalLifecycle.swift", "FunctionalPersistence.swift", "FunctionalFileScopes.swift"]),
        .testTarget(name: "FunctionalProducerModelTests",
            dependencies: ["FunctionalProducerModels", .product(name: "WorkerFixtureSupport", package: "fixtureSupport")]),
        .testTarget(
            name: "FunctionalActionContractTests", dependencies: ["FunctionalActionContract"]),
    ]
)
