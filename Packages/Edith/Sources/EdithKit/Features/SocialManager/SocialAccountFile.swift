import Foundation

public struct SocialAccountFile: Sendable {
    public let url: URL

    public init(url: URL = DataRoot.support.appendingPathComponent("social-manager/accounts.json"))
    {
        self.url = url
    }

    public func load() throws -> SocialAccountCatalog {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SocialAccountCatalog()
        }
        return try JSONDecoder().decode(SocialAccountCatalog.self, from: Data(contentsOf: url))
            .validated()
    }

    public func save(_ catalog: SocialAccountCatalog) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(catalog.validated())
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
}
