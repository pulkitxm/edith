import Foundation

public enum MachineAuth: Codable, Equatable, Hashable, Sendable {
    case agent
    case keyFile(path: String, hasPassphrase: Bool)
    case password

    public var usesAskpass: Bool {
        switch self {
        case .agent: return false
        case let .keyFile(_, hasPassphrase): return hasPassphrase
        case .password: return true
        }
    }

    public var displayName: String {
        switch self {
        case .agent: return "SSH agent"
        case .keyFile: return "Key file"
        case .password: return "Password"
        }
    }
}

public enum MachineSource: Codable, Equatable, Hashable, Sendable {
    case manual
    case sshConfigAlias(String)
}

public struct Machine: Codable, Identifiable, Equatable, Hashable, Sendable {
    public static let localID = UUID(uuidString: "00000000-0000-0000-0000-0000000000ED")!
    public static let local = Machine(
        id: localID, name: "This Mac", host: "localhost", source: .manual,
        createdAt: Date(timeIntervalSince1970: 0))

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: MachineAuth
    public var source: MachineSource
    public var sshClipboardEnabled: Bool
    public var wakeMACAddress: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String = "",
        auth: MachineAuth = .agent, source: MachineSource = .manual,
        sshClipboardEnabled: Bool = false, wakeMACAddress: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.source = source
        self.sshClipboardEnabled = sshClipboardEnabled
        self.wakeMACAddress = wakeMACAddress
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case username
        case auth
        case source
        case sshClipboardEnabled
        case wakeMACAddress
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        username = try values.decode(String.self, forKey: .username)
        auth = try values.decode(MachineAuth.self, forKey: .auth)
        source = try values.decode(MachineSource.self, forKey: .source)
        sshClipboardEnabled =
            try values.decodeIfPresent(Bool.self, forKey: .sshClipboardEnabled) ?? false
        wakeMACAddress = try values.decodeIfPresent(String.self, forKey: .wakeMACAddress)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(host, forKey: .host)
        try values.encode(port, forKey: .port)
        try values.encode(username, forKey: .username)
        try values.encode(auth, forKey: .auth)
        try values.encode(source, forKey: .source)
        try values.encode(sshClipboardEnabled, forKey: .sshClipboardEnabled)
        try values.encodeIfPresent(wakeMACAddress, forKey: .wakeMACAddress)
        try values.encode(createdAt, forKey: .createdAt)
    }

    public static func missing(id: UUID) -> Machine {
        Machine(id: id, name: "Removed machine", host: "")
    }

    public var isMissing: Bool { host.isEmpty && name == "Removed machine" }

    public var sshTarget: String {
        if case let .sshConfigAlias(alias) = source { return alias }
        return username.isEmpty ? host : "\(username)@\(host)"
    }

    public var subtitle: String {
        if case let .sshConfigAlias(alias) = source {
            let resolved = username.isEmpty ? host : "\(username)@\(host)"
            return resolved == alias || host.isEmpty ? alias : "\(alias) · \(resolved)"
        }
        let target = username.isEmpty ? host : "\(username)@\(host)"
        return port == 22 ? target : "\(target):\(port)"
    }
}

public enum MachineConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case reconnecting
    case connected(latencyMillis: Double?)
    case failed(message: String, recoverable: Bool)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .reconnecting: return true
        case let .failed(_, recoverable): return recoverable
        default: return false
        }
    }

    public var failureMessage: String? {
        guard case let .failed(message, _) = self else { return nil }
        return message
    }
}

public struct PortForward: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var machineID: UUID
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int
    public var title: String

    public init(
        id: UUID = UUID(), machineID: UUID, localPort: Int, remoteHost: String = "localhost",
        remotePort: Int, title: String = ""
    ) {
        self.id = id
        self.machineID = machineID
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.title = title
    }

    public var displayName: String {
        title.isEmpty ? "localhost:\(localPort) → \(remoteHost):\(remotePort)" : title
    }

    public var forwardSpec: String {
        "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)"
    }
}

public struct CommandSnippet: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var machineID: UUID?
    public var title: String
    public var command: String

    public init(id: UUID = UUID(), machineID: UUID? = nil, title: String, command: String) {
        self.id = id
        self.machineID = machineID
        self.title = title
        self.command = command
    }
}
