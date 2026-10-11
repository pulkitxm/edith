import Foundation

public enum HostedFunctionalActionError: Error { case invalid }

public enum HostedFunctionalJSON {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= 1_048_576,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw HostedFunctionalActionError.invalid }
        let bytes = Array(data)
        var index = 0
        var scopes: [Set<String>?] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 123 || byte == 91 {
                guard scopes.count < 64 else { throw HostedFunctionalActionError.invalid }
                scopes.append(byte == 123 ? Set<String>() : nil)
            } else if byte == 125 || byte == 93 {
                guard !scopes.isEmpty else { throw HostedFunctionalActionError.invalid }
                scopes.removeLast()
            } else if byte == 34 {
                let start = index
                index += 1
                while index < bytes.count && bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 }
                    index += 1
                }
                guard index < bytes.count else { throw HostedFunctionalActionError.invalid }
                var next = index + 1
                while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count && bytes[next] == 58 {
                    guard !scopes.isEmpty, var names = scopes[scopes.count - 1],
                        let key = try JSONSerialization.jsonObject(
                            with: Data(bytes[start...index]), options: .fragmentsAllowed)
                            as? String,
                        names.insert(key).inserted
                    else { throw HostedFunctionalActionError.invalid }
                    scopes[scopes.count - 1] = names
                }
            }
            index += 1
        }
        guard scopes.isEmpty else { throw HostedFunctionalActionError.invalid }
        return object
    }
}

public struct HostedFunctionalProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let birthSeconds: Int64
    public let birthMicroseconds: Int32
    public let uid: UInt32
    public let executableSHA256: String

    public init(
        pid: Int32, birthSeconds: Int64, birthMicroseconds: Int32, uid: UInt32,
        executableSHA256: String
    ) {
        self.pid = pid
        self.birthSeconds = birthSeconds
        self.birthMicroseconds = birthMicroseconds
        self.uid = uid
        self.executableSHA256 = executableSHA256
    }

    public func validate(uid: UInt32) throws {
        guard pid > 1, birthSeconds > 0, (0..<1_000_000).contains(birthMicroseconds),
            self.uid == uid, HostedFunctionalActionContext.validHash(executableSHA256)
        else { throw HostedFunctionalActionError.invalid }
    }
}

public struct HostedFunctionalOwnedPath: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let kind: String

    public init(name: String, path: String, kind: String) {
        self.name = name
        self.path = path
        self.kind = kind
    }
}

public struct HostedFunctionalActionContext: Codable, Equatable, Sendable {
    public let schema: Int
    public let sourceCommit: String
    public let session: String
    public let owner: String
    public let uid: UInt32
    public let fixtureRoot: String
    public let hostIdentifier: String
    public let home: String
    public let dataDirectory: String
    public let hostABI: String
    public let caseSHA256: String
    public let activationOperation: String
    public let phase: String
    public let pairScope: String
    public let previousVersion: String
    public let currentVersion: String
    public let version: String
    public let packageSHA256: String
    public let engine: HostedFunctionalProcessIdentity
    public let ui: HostedFunctionalProcessIdentity
    public let operations: [String]
    public let ownedPaths: [HostedFunctionalOwnedPath]

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 131_072,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == [
                "schema", "sourceCommit", "session", "owner", "uid", "fixtureRoot",
                "hostIdentifier", "home", "dataDirectory", "hostABI", "caseSHA256",
                "activationOperation", "phase",
                "pairScope", "previousVersion", "currentVersion", "version", "packageSHA256",
                "engine", "ui", "operations", "ownedPaths",
            ],
            let engine = object["engine"] as? [String: Any],
            let ui = object["ui"] as? [String: Any],
            let paths = object["ownedPaths"] as? [[String: Any]],
            Set(engine.keys) == [
                "pid", "birthSeconds", "birthMicroseconds", "uid", "executableSHA256",
            ],
            Set(ui.keys) == Set(engine.keys),
            paths.allSatisfy({ Set($0.keys) == ["name", "path", "kind"] }),
            try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) == data
        else { throw HostedFunctionalActionError.invalid }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func validate(
        source: String, owner: String, session: String, uid: UInt32, root: String,
        caseSHA256: String, engine: HostedFunctionalProcessIdentity,
        ui: HostedFunctionalProcessIdentity
    ) throws {
        guard schema == 1, sourceCommit == source, Self.hex(source, length: 40),
            self.owner == owner, Self.owners.contains(owner), self.session == session,
            Self.uuid(session), self.uid == uid, fixtureRoot == root,
            Self.canonical(root), root.hasSuffix("/functional-fixture-" + session),
            hostIdentifier == "com.pulkit.edith.tests.worker-" + session,
            home == root + "/" + owner + "-home",
            Self.owned(dataDirectory, root: root), hostABI == "edith-host-2",
            self.caseSHA256 == caseSHA256, Self.validHash(caseSHA256),
            ["initial", "updated", "reinstalled"].contains(phase),
            ["synthetic-development", "public-signed-pair"].contains(pairScope),
            Self.increasingVersion(previousVersion, currentVersion),
            pairScope != "synthetic-development"
                || (previousVersion == "1.0.0" && currentVersion == "1.1.0"),
            version == (phase == "initial" ? previousVersion : currentVersion),
            Self.validHash(packageSHA256), self.engine == engine, self.ui == ui,
            engine.pid != ui.pid, !operations.isEmpty, operations.count <= 16,
            Set(operations).count == operations.count, operations.contains(activationOperation),
            operations.allSatisfy(Self.operation), !ownedPaths.isEmpty, ownedPaths.count <= 32,
            Set(ownedPaths.map(\.name)).count == ownedPaths.count,
            Set(ownedPaths.map(\.path)).count == ownedPaths.count,
            ownedPaths.allSatisfy({
                Self.text($0.name, maximum: 256) && Self.owned($0.path, root: root)
                    && ["file", "directory"].contains($0.kind)
            })
        else { throw HostedFunctionalActionError.invalid }
        try engine.validate(uid: uid)
        try ui.validate(uid: uid)
    }

    public func ownedPath(named name: String, kind: String) throws -> URL {
        guard let entry = ownedPaths.first(where: { $0.name == name && $0.kind == kind }),
            Self.owned(entry.path, root: fixtureRoot)
        else { throw HostedFunctionalActionError.invalid }
        return URL(fileURLWithPath: entry.path, isDirectory: kind == "directory")
    }

    public func requireOperation(_ operation: String) throws {
        guard operations.contains(operation) else { throw HostedFunctionalActionError.invalid }
    }

    public static let owners: Set<String> = [
        "keepAwake", "audioMixer", "focusDim", "windowSweaters", "micMute",
        "keystrokeHighlight", "presenter", "colorPicker", "systemStats", "emoji",
        "homebrew", "calendar", "jev", "system", "timeLapse", "cleaner", "appMaintenance",
        "blitztree", "plugins", "notchShelf", "clipboard", "music", "docs", "latex",
        "companion", "terminal", "studio", "usage", "bifrost", "lidAwake", "attention",
        "machines", "downloads", "seoAudit", "virtualCamera", "codeStats", "herdr",
        "quinjet", "database",
    ]

    public static func validHash(_ value: String) -> Bool { hex(value, length: 64) }

    private static func hex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private static func uuid(_ value: String) -> Bool {
        guard let parsed = UUID(uuidString: value), parsed.uuidString.lowercased() == value,
            value.utf8.count == 36
        else { return false }
        let bytes = Array(value.utf8)
        return bytes[14] == 52 && [56, 57, 97, 98].contains(bytes[19])
    }

    private static func text(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    private static func canonical(_ value: String) -> Bool {
        guard text(value, maximum: 4096), value.hasPrefix("/"), !value.hasSuffix("/") else {
            return false
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.first == ""
            && parts.dropFirst().allSatisfy { $0 != "" && $0 != "." && $0 != ".." }
    }

    private static func owned(_ value: String, root: String) -> Bool {
        canonical(value) && value.hasPrefix(root + "/")
    }

    private static func increasingVersion(_ before: String, _ after: String) -> Bool {
        func parts(_ value: String) -> [UInt64]? {
            guard value.utf8.count <= 80 else { return nil }
            let fields = value.split(separator: ".", omittingEmptySubsequences: false)
            guard fields.count == 3,
                fields.allSatisfy({
                    !$0.isEmpty && ($0 == "0" || $0.first != "0")
                        && $0.utf8.allSatisfy { (48...57).contains($0) }
                })
            else { return nil }
            let numbers = fields.compactMap { UInt64($0) }
            return numbers.count == 3 ? numbers : nil
        }
        guard let a = parts(before), let b = parts(after) else { return false }
        return a.lexicographicallyPrecedes(b)
    }

    private static func operation(_ value: String) -> Bool {
        guard text(value, maximum: 128) else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2
            && parts.allSatisfy { part in
                guard let first = part.utf8.first,
                    (65...90).contains(first) || (97...122).contains(first)
                else { return false }
                return part.utf8.allSatisfy {
                    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                        || [45, 95].contains($0)
                }
            }
    }
}

@MainActor
public protocol HostedFunctionalActionCase {
    static var owner: String { get }
    static var activationOperation: String { get }
    func activateOriginalControl(context: HostedFunctionalActionContext) async throws
    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data
    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data?
    func shutdownPresentation() async
}
