// swift-tools-version:6.0
import PackageDescription

let engineDependencies: [Target.Dependency] = [
    "DatabaseCore",
    .product(name: "Crypto", package: "swift-crypto"),
    .product(name: "GRDB", package: "GRDB.swift"),
    .product(name: "RediStack", package: "RediStack"),
    .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "NIOPosix", package: "swift-nio"),
    .product(name: "MongoKitten", package: "MongoKitten"),
    .product(name: "MongoClient", package: "MongoKitten"),
    .product(name: "MongoCore", package: "MongoKitten"),
    .product(name: "Logging", package: "swift-log"),
    .product(name: "NIOSSL", package: "swift-nio-ssl"),
    .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
    .product(name: "PostgresNIO", package: "postgres-nio"),
    .product(name: "MySQLNIO", package: "mysql-nio"),
]

let package = Package(
    name: "DatabaseEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "DatabaseEngine", type: .dynamic, targets: ["DatabaseCore", "DatabaseEngine"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
        .package(url: "https://github.com/swift-server/RediStack.git", exact: "1.6.3"),
        .package(url: "https://github.com/orlandos-nl/MongoKitten.git", exact: "7.16.3"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.2"),
        .package(
            url: "https://github.com/apple/swift-nio-transport-services.git", exact: "1.28.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.33.1"),
        .package(
            url: "https://github.com/vapor/mysql-nio.git",
            revision: "a9378d6ed22899b7df72894719cc3df51a37fb18"),
    ],
    targets: [
        .target(name: "DatabaseCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "DatabaseEngine", dependencies: engineDependencies,
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "DatabaseEngineTests",
            dependencies: engineDependencies + [
                "DatabaseEngine",
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
