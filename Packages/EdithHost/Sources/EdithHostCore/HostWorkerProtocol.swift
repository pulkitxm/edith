import EdithExtensionSupport
import Foundation

public struct HostWorkerConfiguration: Codable, Sendable {
    public let identifier: String
    public let supportDirectory: URL
    public let extensionID: String
    public let version: String
    public let theme: String
    public let appearance: String
    public let zoom: Double
    public var recoveryOnly: Bool = false
    public let publicLauncher: HostPublicLauncher?
    public private(set) var ambientPolicy: HostAmbientPolicy

    public init(
        identity: HostIdentity, extensionID: String, version: String,
        publicLauncher: HostPublicLauncher? = nil, ambientPolicy: HostAmbientPolicy? = nil
    ) {
        self.publicLauncher = publicLauncher
        identifier = identity.identifier
        supportDirectory =
            identity.development
            ? identity.root.deletingLastPathComponent().deletingLastPathComponent()
            : identity.root.deletingLastPathComponent()
        self.extensionID = extensionID
        self.version = version
        let preferences = SharedDefaults.applicationStore(identifier: identity.identifier)
        self.ambientPolicy =
            ambientPolicy
            ?? .initial(
                owner: extensionID,
                pauseAmbientOnBattery: preferences?.bool(
                    forKey: HostCoreBackgroundPolicy.preferenceKey) ?? false)
        theme = preferences?.string(forKey: AppStorageKeys.General.theme) ?? "accent"
        appearance = preferences?.string(forKey: AppStorageKeys.General.appearance) ?? "system"
        let storedZoom = preferences?.double(forKey: AppStorageKeys.General.mainWindowZoom) ?? 1
        zoom = storedZoom.isFinite && storedZoom > 0 ? min(1.6, max(0.8, storedZoom)) : 1
    }

    public func replacingAmbientPolicy(_ policy: HostAmbientPolicy) -> Self {
        var next = self
        next.ambientPolicy = policy
        return next
    }

    public func identity() throws -> HostIdentity {
        try HostIdentity(identifier: identifier, supportDirectory: supportDirectory)
    }
}

public enum HostWorkerSynchronization: String, Sendable {
    case settings = "synchronize"
    case ambientPolicy

    private func admitted(
        _ request: HostWorkerRequest, current: HostWorkerConfiguration
    ) throws -> HostWorkerConfiguration {
        guard request.operation == rawValue, let next = request.configuration,
            !current.recoveryOnly, !next.recoveryOnly,
            next.identifier == current.identifier,
            next.supportDirectory == current.supportDirectory,
            next.extensionID == current.extensionID, next.version == current.version,
            self != .ambientPolicy || HostAmbientPolicy.jobs[current.extensionID] != nil
        else { throw HostWorkerError.rejected }
        try next.ambientPolicy.validate(owner: next.extensionID)
        return next
    }

    @MainActor public func apply(
        _ request: HostWorkerRequest, current: HostWorkerConfiguration,
        appearance: (HostWorkerConfiguration) throws -> Void,
        synchronize: (String, NSDictionary) throws -> Void
    ) throws -> HostWorkerConfiguration {
        let next = try admitted(request, current: current)
        guard
            var context = try next.ambientPolicy.context(owner: next.extensionID)
                as? [String: Any]
        else { throw HostWorkerError.invalidResponse }
        let identity = try next.identity()
        context["hostIdentifier"] = identity.identifier
        context["defaultsSuite"] = identity.extensionDefaultsSuite(next.extensionID)
        context["dataDirectory"] = identity.extensionDirectory(next.extensionID).path
        if self == .ambientPolicy {
            context["ambientPolicyOnly"] = true
        } else {
            try appearance(next)
        }
        try synchronize(next.extensionID, NSDictionary(dictionary: context))
        return self == .ambientPolicy ? current.replacingAmbientPolicy(next.ambientPolicy) : next
    }

    @MainActor func acknowledged(
        current: HostWorkerConfiguration, next: HostWorkerConfiguration,
        send: (HostWorkerRequest) async throws -> HostWorkerResponse
    ) async throws -> HostWorkerConfiguration {
        let request = HostWorkerRequest(operation: rawValue, configuration: next)
        _ = try admitted(request, current: current)
        try Task.checkCancellation()
        let response = try await send(request)
        try Task.checkCancellation()
        guard response.token == request.token, response.ok, response.version == current.version
        else {
            throw HostWorkerError.invalidResponse
        }
        return self == .ambientPolicy ? current.replacingAmbientPolicy(next.ambientPolicy) : next
    }
}

public enum HostWorkerStopReason: String, Codable, CaseIterable, Sendable {
    case applicationQuit
    case disable
    case update
    case removal
    case shutdown
    case ownerLost
}

public struct HostWorkerRequest: Codable, Sendable {
    public let token: UUID
    public let operation: String
    public let configuration: HostWorkerConfiguration?
    public let navigation: HostWorkerNavigationReply?
    public let stopReason: HostWorkerStopReason?

    public init(
        token: UUID = UUID(), operation: String, configuration: HostWorkerConfiguration? = nil,
        navigation: HostWorkerNavigationReply? = nil, stopReason: HostWorkerStopReason? = nil
    ) {
        self.token = token
        self.operation = operation
        self.configuration = configuration
        self.navigation = navigation
        self.stopReason = stopReason
    }
}

public struct HostWorkerResponse: Codable, Sendable {
    public let token: UUID
    public let ok: Bool
    public let version: String?
    public let message: String?

    public init(token: UUID, ok: Bool, version: String? = nil, message: String? = nil) {
        self.token = token
        self.ok = ok
        self.version = version
        self.message = message
    }
}

public struct HostWorkerProcessGroup: Codable, Sendable {
    public let kind: String
    public let pid: Int32
    public let registered: Bool
    public let generation: String

    public init(pid: Int32, generation: String, registered: Bool) {
        kind = "processGroup"
        self.pid = pid
        self.registered = registered
        self.generation = generation
    }
}

public struct HostWorkerNavigationRequest: Codable, Sendable {
    public let kind: String
    public let token: UUID
    public let extensionID: String
    public let version: String
    public let section: String?
    public let relativePath: String?
    public let presentationID: UUID?
    public let location: String?
    public let machinesWindow: HostMachinesWindowTarget?
    public let herdrWindow: HostHerdrWindowTarget?
    public let folderChoice: Bool?

    public init(
        token: UUID = UUID(), configuration: HostWorkerConfiguration, section: String? = nil,
        relativePath: String? = nil, presentationID: UUID? = nil, location: String? = nil,
        machinesWindow: HostMachinesWindowTarget? = nil, herdrWindow: HostHerdrWindowTarget? = nil,
        folderChoice: Bool? = nil
    ) {
        kind = "navigation"
        self.token = token
        extensionID = configuration.extensionID
        version = configuration.version
        self.section = section
        self.relativePath = relativePath
        self.presentationID = presentationID
        self.location = location
        self.machinesWindow = machinesWindow
        self.herdrWindow = herdrWindow
        self.folderChoice = folderChoice
    }

    public func validate(configuration: HostWorkerConfiguration) throws {
        guard kind == "navigation", extensionID == configuration.extensionID,
            version == configuration.version,
            section.map({
                !$0.isEmpty && $0.utf8.count <= 128
                    && $0.allSatisfy {
                        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
                    }
            }) ?? true,
            machinesWindow != nil || herdrWindow != nil
                || (presentationID == nil) == (location == nil),
            location.map({
                [
                    "main", "settings", "home", "notch", "sidebar.utility", "music.footer",
                    "music.sidebar", "music.detail", "machines.window",
                ].contains($0)
            }) ?? true
        else { throw HostWorkerError.invalidResponse }
        if let folderChoice {
            guard folderChoice, extensionID == "herdr", presentationID != nil,
                location == "settings", section == "agentActivity", relativePath == nil,
                machinesWindow == nil, herdrWindow == nil
            else { throw HostWorkerError.invalidResponse }
        }
        if let machinesWindow {
            guard extensionID == "machines", presentationID != nil, location == nil,
                section == nil, relativePath == nil, herdrWindow == nil
            else { throw HostWorkerError.invalidResponse }
            try machinesWindow.validate()
        }
        if let herdrWindow {
            guard extensionID == "herdr", presentationID != nil, location == nil,
                section == nil, relativePath == nil, machinesWindow == nil
            else { throw HostWorkerError.invalidResponse }
            try herdrWindow.validate()
        }
        if let relativePath {
            guard extensionID == "music", relativePath.utf8.count <= 4096,
                !relativePath.isEmpty, !relativePath.hasPrefix("/"),
                !relativePath.utf8.contains(0), !relativePath.contains("\\"),
                relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                    !$0.isEmpty && $0 != "." && $0 != ".."
                })
            else { throw HostWorkerError.invalidResponse }
        }
    }
}

public struct HostWorkerNavigationReply: Codable, Sendable {
    public let token: UUID
    public let extensionID: String
    public let version: String
    public let ok: Bool
    public let selectedPath: String?
    public let folderCancelled: Bool?

    public init(
        request: HostWorkerNavigationRequest, ok: Bool, folderResult: HostFolderChoiceResult? = nil
    ) {
        token = request.token
        extensionID = request.extensionID
        version = request.version
        self.ok = ok
        selectedPath = folderResult?.selectedPath
        folderCancelled = folderResult?.cancelled
    }

    public func validate(configuration: HostWorkerConfiguration) throws {
        guard extensionID == configuration.extensionID, version == configuration.version else {
            throw HostWorkerError.invalidResponse
        }
        if selectedPath != nil || folderCancelled != nil {
            guard ok, extensionID == "herdr" else { throw HostWorkerError.invalidResponse }
            try HostFolderChoiceResult(selectedPath: selectedPath, cancelled: folderCancelled)
                .validate()
        }
    }
}

public struct HostWorkerNavigationCancel: Codable, Sendable {
    public let kind: String
    public let token: UUID
    public let extensionID: String
    public let version: String

    public init(token: UUID, configuration: HostWorkerConfiguration) {
        kind = "navigationCancel"
        self.token = token
        extensionID = configuration.extensionID
        version = configuration.version
    }

    public func validate(configuration: HostWorkerConfiguration) throws {
        guard kind == "navigationCancel", extensionID == configuration.extensionID,
            version == configuration.version
        else { throw HostWorkerError.invalidResponse }
    }
}

public enum HostWorkerError: Error, Equatable {
    case exited
    case timedOut
    case invalidResponse
    case rejected
    case stillRunning
    case disableRejected(String)
}

public struct HostWorkerFrames: Sendable {
    public static let maximumBytes = 65_536
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        var frames: [Data] = []
        for byte in data {
            if byte == 10 {
                guard !buffer.isEmpty else { throw HostWorkerError.invalidResponse }
                frames.append(buffer)
                buffer.removeAll(keepingCapacity: true)
            } else {
                guard buffer.count < Self.maximumBytes else {
                    throw HostWorkerError.invalidResponse
                }
                buffer.append(byte)
            }
        }
        return frames
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw HostWorkerError.invalidResponse }
        data.append(10)
        return data
    }
}

public extension HostWorkerError {
    var disableMessage: String {
        if case .disableRejected(let message) = self { return message }
        return
            "Cleanup is pending. Restore system settings or finish macOS approval, then try again."
    }
}
