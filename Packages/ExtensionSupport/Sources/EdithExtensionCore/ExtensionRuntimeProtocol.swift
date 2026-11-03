import AppKit
import Foundation

public enum ExtensionRuntimeAPI {
    public static let version = 1
    public static let supportedVersions = 1...1
}

public struct ExtensionRuntimeDescription {
    public let id: String
    public let role: String
    public let version: String
    public let hostABI: String
    public let apiVersion: Int

    public init(id: String, role: String, version: String, hostABI: String, apiVersion: Int) {
        self.id = id
        self.role = role
        self.version = version
        self.hostABI = hostABI
        self.apiVersion = apiVersion
    }
}

public enum ExtensionRuntimeRequest {
    case describe
    case start(ExtensionHostContext)
    case synchronize(ExtensionHostContext)
    case configureUI(ExtensionUIConfiguration)
    case view(UUID, ExtensionHostContext)
    case stopUI(UUID?)
    case cancelCommand(UUID)
    case stop
    case status
    case custom(String, NSDictionary)

    @MainActor public init?(operation: String, context: NSDictionary) {
        switch operation {
        case "describe": self = .describe
        case "start": self = .start(ExtensionHostContext(input: context))
        case "synchronize": self = .synchronize(ExtensionHostContext(input: context))
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: context) else { return nil }
            self = .configureUI(configuration)
        case "view":
            guard let value = context["presentationID"] as? String,
                let presentation = UUID(uuidString: value)
            else { return nil }
            self = .view(presentation, ExtensionHostContext(input: context))
        case "stopUI":
            if let value = context["presentationID"] {
                guard let text = value as? String, let presentation = UUID(uuidString: text)
                else { return nil }
                self = .stopUI(presentation)
            } else {
                self = .stopUI(nil)
            }
        case "cancelCommand":
            guard let value = context["token"] as? String, let token = UUID(uuidString: value)
            else { return nil }
            self = .cancelCommand(token)
        case "stop": self = .stop
        case "status": self = .status
        default: self = .custom(operation, context)
        }
    }
}

public enum ExtensionRuntimeResponse {
    case description(ExtensionRuntimeDescription)
    case result(Bool)
    case status(running: Bool, details: [String: Any])
    case view(NSViewController)
    case custom(NSObject)

    public var object: NSObject {
        switch self {
        case let .description(value):
            return [
                "id": value.id, "role": value.role, "version": value.version,
                "hostABI": value.hostABI, "runtimeAPIVersion": value.apiVersion,
            ] as NSDictionary
        case let .result(ok): return ["ok": ok] as NSDictionary
        case let .status(running, details):
            var values = details
            values["ok"] = true
            values["running"] = running
            return values as NSDictionary
        case let .view(controller): return controller
        case let .custom(value): return value
        }
    }
}

@MainActor
public protocol ExtensionRuntimeProtocol: AnyObject {
    var runtimeAPIVersion: Int { get }
    var supportsDisablePreparation: Bool { get }
    var supportsPresentationPreparation: Bool { get }
    func dispatch(_ request: ExtensionRuntimeRequest) -> ExtensionRuntimeResponse
    func invokeCommand(_ command: String, token: UUID, payload: Data) async throws -> Data
    func suspend() async
    func prepareForDisable() async throws
    func prepareForStop() async
    func preparePresentationToClose(_ presentation: UUID) async -> String?
}
