import EdithExtensionSupport
import Foundation

public enum HostCLIError: Error, LocalizedError, Sendable {
    case usage(String)
    case unavailable
    case rejected(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .usage(let message), .rejected(let message): message
        case .unavailable:
            "Edith is not running for this app installation. Open this Edith app and try again."
        case .timedOut: "The command timed out and was cancelled."
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .usage: 2
        case .unavailable: 3
        case .rejected: 1
        case .timedOut: 4
        }
    }
}

public struct HostCLIRequest: Sendable, Equatable {
    public enum Action: String, Sendable {
        case ls, info, install, update, enable, disable, remove, invoke, terminal
    }
    public let action: Action
    public let id: String?
    public let operation: String?
    public let payload: Data
    public let timeout: Double
    public let raw: Bool
    public static let maximumPayload = 512 * 1024

    public init(
        action: Action, id: String? = nil, operation: String? = nil,
        payload: Data = Data("{}".utf8), timeout: Double = 30, raw: Bool = false
    ) throws {
        self.action = action
        self.id = id
        self.operation = operation
        self.payload = payload
        self.timeout = timeout
        self.raw = raw
        try validate()
    }

    public func encoded() throws -> Data {
        var object: [String: Any] = [
            "action": action.rawValue, "payload": payload.base64EncodedString(), "timeout": timeout,
        ]
        object["id"] = id
        object["operation"] = operation
        return try JSONSerialization.data(withJSONObject: object)
    }

    public static func decoded(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys).isSubset(of: ["action", "id", "operation", "payload", "timeout"]),
            let value = object["action"] as? String, let action = Action(rawValue: value),
            let encoded = object["payload"] as? String, let payload = Data(base64Encoded: encoded),
            let timeout = object["timeout"] as? NSNumber,
            CFGetTypeID(timeout) != CFBooleanGetTypeID(),
            object["id"] == nil || object["id"] is String,
            object["operation"] == nil || object["operation"] is String
        else { throw HostCLIError.usage("Invalid command request.") }
        return try Self(
            action: action, id: object["id"] as? String,
            operation: object["operation"] as? String, payload: payload,
            timeout: timeout.doubleValue)
    }

    public func validate() throws {
        guard timeout.isFinite, (1...120).contains(timeout), payload.count <= Self.maximumPayload,
            (try? JSONSerialization.jsonObject(with: payload, options: .fragmentsAllowed)) != nil
        else { throw HostCLIError.usage("Invalid JSON payload or command limit.") }
        guard !raw || action == .invoke else {
            throw HostCLIError.usage("Only invoke supports --raw.")
        }
        if action == .ls {
            guard id == nil, operation == nil else {
                throw HostCLIError.usage("Invalid list command.")
            }
        } else {
            guard let id, !id.isEmpty, id.utf8.count <= 80,
                id.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0)
                        || (97...122).contains($0) || $0 == 45
                })
            else { throw HostCLIError.usage("Invalid extension identifier.") }
        }
        if action == .terminal {
            guard id == "calendar", operation == "calendar.cli", !raw,
                let request = try? JSONDecoder().decode(ExtensionCLIRequest.self, from: payload),
                (try? request.validate()) != nil
            else { throw HostCLIError.usage("Invalid extension terminal command.") }
        } else if action == .invoke {
            guard let operation, !operation.isEmpty, operation.utf8.count <= 128,
                operation.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0)
                        || (97...122).contains($0) || [45, 46, 95].contains($0)
                }),
                !operation.hasPrefix("extension.")
            else { throw HostCLIError.usage("Invalid worker operation.") }
        } else if operation != nil || payload != Data("{}".utf8) {
            throw HostCLIError.usage("Only invoke accepts a worker operation and payload.")
        }
    }
}

public enum HostCLICommand: Equatable {
    case help, version, request(HostCLIRequest), terminal(HostCLIRequest)

    public static let usageText = """
        usage: ed extensions ls [--json]
               ed extensions info|install|update|enable|disable|remove <id> [--json]
               ed invoke <id> <operation> [--json <json|->] [--timeout <seconds>] [--raw]
               ed calendar [ls|open|join|directions] [arguments]
               ed --help | --version

        Results are JSON. Use --json - to read an invoke payload from stdin.
        Edith must already be running. Invoke requires a compatible, enabled worker.
        Commands never open the app or enable a worker implicitly.
        Timeout: 1 to 120 seconds, default 30. Payload limit: 512 KiB.
        """

    public static func parse(
        _ arguments: [String],
        readInput: () throws -> Data = {
            try FileHandle.standardInput.read(upToCount: HostCLIRequest.maximumPayload + 1)
                ?? Data()
        }
    ) throws -> Self {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"]
            || arguments == ["extensions", "--help"] || arguments == ["invoke", "--help"]
        {
            return .help
        }
        if arguments == ["--version"] || arguments == ["version"] { return .version }
        if arguments.first == "calendar" {
            let request: ExtensionCLIRequest
            do { request = try ExtensionCLIRequest(arguments: Array(arguments.dropFirst())) } catch
            { throw HostCLIError.usage("The terminal arguments exceed their limits.") }
            return .terminal(
                try HostCLIRequest(
                    action: .terminal, id: "calendar", operation: "calendar.cli",
                    payload: JSONEncoder().encode(request)))
        }
        if arguments.first == "extensions" {
            var args = Array(arguments.dropFirst())
            if args.last == "--json" { args.removeLast() }
            guard let word = args.first, let action = HostCLIRequest.Action(rawValue: word),
                action != .invoke, action != .terminal,
                args.count == (action == .ls ? 1 : 2)
            else { throw HostCLIError.usage("Unknown extensions command. Run ed --help.") }
            return .request(try HostCLIRequest(action: action, id: args.count == 2 ? args[1] : nil))
        }
        guard arguments.first == "invoke", arguments.count >= 3 else {
            throw HostCLIError.usage("Unknown command. Run ed --help.")
        }
        var payload = Data("{}".utf8)
        var timeout = 30.0
        var raw = false
        var seen = Set<String>()
        var index = 3
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--raw", seen.insert(flag).inserted {
                raw = true; index += 1; continue
            }
            guard ["--json", "--timeout"].contains(flag), seen.insert(flag).inserted,
                index + 1 < arguments.count
            else { throw HostCLIError.usage("Invalid invoke arguments. Run ed --help.") }
            let value = arguments[index + 1]
            if flag == "--json" {
                payload = value == "-" ? try readInput() : Data(value.utf8)
            } else {
                guard let seconds = Double(value) else {
                    throw HostCLIError.usage("Invalid timeout.")
                }
                timeout = seconds
            }
            index += 2
        }
        return .request(
            try HostCLIRequest(
                action: .invoke, id: arguments[1],
                operation: arguments[2], payload: payload, timeout: timeout, raw: raw))
    }
}
