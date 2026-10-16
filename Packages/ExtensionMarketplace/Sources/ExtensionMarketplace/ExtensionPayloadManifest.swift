import Foundation

public struct ExtensionPayloadManifest: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let hostABI: String
    public let architecture: String
    public let minimumSystemVersion: ExtensionSystemVersion
    public let dependencies: [String]

    public init(package: ExtensionPackage) {
        id = package.id
        version = package.version
        hostABI = package.hostABI
        architecture = package.architecture
        minimumSystemVersion = package.minimumSystemVersion
        dependencies = package.dependencies
    }
}
