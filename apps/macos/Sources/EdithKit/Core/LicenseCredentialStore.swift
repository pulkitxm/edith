import Foundation

public enum LicenseCredentialItem: String, CaseIterable, Sendable {
    case deviceId = "device-id"
    case deviceKey = "device-key"
    case refreshCredential = "refresh-credential"
    case accessToken = "access-token"
    case entitlement = "entitlement"
    case trustedTime = "trusted-time"
}

public protocol LicenseCredentialStoring {
    func read(_ item: LicenseCredentialItem) throws -> String?
    func write(_ value: String, item: LicenseCredentialItem) throws
    func delete(_ item: LicenseCredentialItem) throws
}

public struct FileLicenseCredentialStore: LicenseCredentialStoring {
    private let directory: URL

    public init(directory: URL = AppData.supportDir) {
        self.directory = directory
    }

    public func read(_ item: LicenseCredentialItem) throws -> String? {
        let url = fileURL(item)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func write(_ value: String, item: LicenseCredentialItem) throws {
        let url = fileURL(item)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func delete(_ item: LicenseCredentialItem) throws {
        let url = fileURL(item)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(_ item: LicenseCredentialItem) -> URL {
        directory.appendingPathComponent(item.rawValue)
    }
}

public final class InMemoryLicenseCredentialStore: LicenseCredentialStoring {
    private var values: [LicenseCredentialItem: String] = [:]

    public init() {}

    public func read(_ item: LicenseCredentialItem) throws -> String? {
        values[item]
    }

    public func write(_ value: String, item: LicenseCredentialItem) throws {
        values[item] = value
    }

    public func delete(_ item: LicenseCredentialItem) throws {
        values[item] = nil
    }
}
