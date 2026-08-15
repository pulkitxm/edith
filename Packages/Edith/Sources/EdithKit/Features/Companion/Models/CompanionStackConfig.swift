import Foundation
import Security

public struct CompanionStackConfig: Codable, Equatable, Sendable {
    public var pgPassword: String
    public var apiPort: Int
    public var pgPort: Int
    public var redisPort: Int
    public var embedModel: String
    public var visionModel: String
    public var sttModel: String
    public var reasonProvider: String
    public var reasonURL: String
    public var reasonModel: String
    public var reflectAt: String

    public init(
        pgPassword: String = "companion-dev",
        apiPort: Int = 4820,
        pgPort: Int = 5432,
        redisPort: Int = 6379,
        embedModel: String = "qwen3-embedding:0.6b",
        visionModel: String = "qwen3-vl:2b",
        sttModel: String = "ggml-base.bin",
        reasonProvider: String = "openai",
        reasonURL: String = "http://ollama:11434/v1",
        reasonModel: String = "qwen3:1.7b",
        reflectAt: String = "02:00"
    ) {
        self.pgPassword = pgPassword
        self.apiPort = apiPort
        self.pgPort = pgPort
        self.redisPort = redisPort
        self.embedModel = embedModel
        self.visionModel = visionModel
        self.sttModel = sttModel
        self.reasonProvider = reasonProvider
        self.reasonURL = reasonURL
        self.reasonModel = reasonModel
        self.reflectAt = reflectAt
    }

    public var sttModelName: String {
        sttModel
            .replacingOccurrences(of: "ggml-", with: "")
            .replacingOccurrences(of: ".bin", with: "")
    }

    public func envFile(secrets: CompanionSecretValues = CompanionSecretValues()) -> String {
        let rows: [(String, String)] = [
            ("COMPANION_PG_PASSWORD", pgPassword),
            ("COMPANION_PG_PORT", String(pgPort)),
            ("COMPANION_REDIS_PORT", String(redisPort)),
            ("COMPANION_API_BIND", "127.0.0.1"),
            ("COMPANION_API_PORT", String(apiPort)),
            ("COMPANION_EMBED_MODEL", embedModel),
            ("COMPANION_VLM_MODEL", visionModel),
            ("COMPANION_STT_MODEL", sttModel),
            ("COMPANION_STT_MODEL_NAME", sttModelName),
            ("COMPANION_REASON_PROVIDER", reasonProvider),
            ("COMPANION_REASON_URL", reasonURL),
            ("COMPANION_REASON_MODEL", reasonModel),
            ("COMPANION_REFLECT_AT", reflectAt),
            ("ANTHROPIC_API_KEY", secrets.anthropicKey),
            ("GITHUB_TOKEN", secrets.githubToken),
            ("NOTION_TOKEN", secrets.notionToken),
        ]
        return rows.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
    }

    public var portsUsed: [Int] { [apiPort, pgPort, redisPort] }

    public func validated() -> [String] {
        var problems: [String] = []
        for port in portsUsed where !(1...65535).contains(port) {
            problems.append("port \(port) is out of range")
        }
        if Set(portsUsed).count != portsUsed.count {
            problems.append("the api, postgres and redis ports must differ")
        }
        if pgPassword.isEmpty { problems.append("the postgres password cannot be empty") }
        if reasonProvider == "openai", reasonURL.isEmpty {
            problems.append("a local reasoner needs an endpoint URL")
        }
        return problems
    }
}

public struct CompanionSecretValues: Equatable, Sendable {
    public var anthropicKey: String
    public var githubToken: String
    public var notionToken: String

    public init(anthropicKey: String = "", githubToken: String = "", notionToken: String = "") {
        self.anthropicKey = anthropicKey
        self.githubToken = githubToken
        self.notionToken = notionToken
    }

    public var isEmpty: Bool {
        anthropicKey.isEmpty && githubToken.isEmpty && notionToken.isEmpty
    }
}

public enum CompanionSecretKind: String, CaseIterable, Sendable {
    case anthropicKey
    case githubToken
    case notionToken

    public var displayName: String {
        switch self {
        case .anthropicKey: "Anthropic API key"
        case .githubToken: "GitHub token"
        case .notionToken: "Notion token"
        }
    }
}

public enum CompanionSecrets {
    public static let service = "com.pulkit.edith.companion"

    public static func set(_ secret: String, kind: CompanionSecretKind) {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
        guard !secret.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Edith Companion"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public static func get(_ kind: CompanionSecretKind) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func clear(_ kind: CompanionSecretKind) {
        set("", kind: kind)
    }

    public static func all() -> CompanionSecretValues {
        CompanionSecretValues(
            anthropicKey: get(.anthropicKey) ?? "",
            githubToken: get(.githubToken) ?? "",
            notionToken: get(.notionToken) ?? "")
    }

    public static func hint(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return trimmed.isEmpty ? nil : "set" }
        return "set, ending \(trimmed.suffix(4))"
    }
}

public enum CompanionConfigStore {
    public static var file: URL {
        MachinePaths.root.appendingPathComponent("companion-config.json")
    }

    public static func load(_ url: URL = file) -> CompanionStackConfig {
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(CompanionStackConfig.self, from: data)
        else { return CompanionStackConfig() }
        return config
    }

    @discardableResult
    public static func save(_ config: CompanionStackConfig, to url: URL = file)
        -> CompanionStackConfig
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return config }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        return config
    }
}

public struct CompanionConfigBundle: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var exportedAt: Date
    public var config: CompanionStackConfig
    public var deployment: CompanionDeployment?

    public init(
        version: Int = currentVersion, exportedAt: Date = Date(),
        config: CompanionStackConfig, deployment: CompanionDeployment?
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.config = config
        self.deployment = deployment
    }

    public static func encode(_ bundle: CompanionConfigBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    public static func decode(_ data: Data) throws -> CompanionConfigBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let probe = try? decoder.decode(VersionProbe.self, from: data),
            probe.version > currentVersion
        {
            throw CompanionConfigError.newerThanThisApp(probe.version)
        }
        return try decoder.decode(CompanionConfigBundle.self, from: data)
    }
}

public enum CompanionConfigError: Error, Equatable, LocalizedError {
    case newerThanThisApp(Int)

    public var errorDescription: String? {
        switch self {
        case let .newerThanThisApp(version):
            "This configuration was exported by a newer Edith (format \(version))."
        }
    }
}
