import Foundation

public struct HerdrTerminalBridgeSpecification: Codable, Equatable, Sendable {
    public static let columnsToken = "{columns}"
    public static let rowsToken = "{rows}"

    public let executable: String
    public let arguments: [String]
    public let environment: [String]

    public init(controller: TerminalLaunchRequest) {
        executable = controller.executable
        arguments = controller.arguments
        environment = controller.environment
    }

    public init(encoded: String) throws {
        guard let data = Data(base64Encoded: encoded) else {
            throw HerdrTerminalBridgeError.invalidSpecification
        }
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw HerdrTerminalBridgeError.invalidSpecification
        }
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self).base64EncodedString()
    }

    public func request(columns: UInt16, rows: UInt16) -> TerminalLaunchRequest {
        let replacements = [
            Self.columnsToken: String(columns),
            Self.rowsToken: String(rows),
        ]
        return TerminalLaunchRequest(
            executable: executable,
            arguments: arguments.map { argument in
                replacements.reduce(argument) { value, replacement in
                    value.replacingOccurrences(of: replacement.key, with: replacement.value)
                }
            },
            environment: environment)
    }
}

public enum HerdrTerminalBridgeError: LocalizedError {
    case invalidSpecification
    case invalidRecord
    case executableUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidSpecification:
            "The Herdr terminal bridge specification is invalid."
        case .invalidRecord:
            "Herdr returned an invalid terminal record."
        case .executableUnavailable:
            "The bundled Edith command could not be found."
        }
    }
}

public enum HerdrTerminalBridgeRecord: Equatable, Sendable {
    case frame(Data)
    case closed
    case ignored
}

public enum HerdrTerminalBridge {
    public static let startSequence = Data(
        "\u{1B}[?1049h\u{1B}[?1006l\u{1B}[?1016l\u{1B}[?1015l\u{1B}[?1005l\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h\u{1B}[?1004h\u{1B}[?2004h\u{1B}[?7l"
            .utf8)
    public static let stopSequence = Data(
        "\u{1B}[?1006l\u{1B}[?1016l\u{1B}[?1015l\u{1B}[?1005l\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?1004l\u{1B}[?2004l\u{1B}[?7h\u{1B}[?25h\u{1B}[?1049l"
            .utf8)

    public static func executable(
        bundle: Bundle = .main, fileManager: FileManager = .default
    ) -> URL? {
        if let sibling = bundle.executableURL?.deletingLastPathComponent().appendingPathComponent(
            "ed"), fileManager.isExecutableFile(atPath: sibling.path)
        {
            return sibling
        }
        return CLIToolEnvironment.executable(named: "ed")
    }

    public static func launchRequest(
        bridgeExecutable: URL, controller: TerminalLaunchRequest
    ) throws -> TerminalLaunchRequest {
        let specification = try HerdrTerminalBridgeSpecification(controller: controller).encoded()
        return TerminalLaunchRequest(
            executable: bridgeExecutable.path,
            arguments: ["herdr", "bridge", specification],
            environment: controller.environment)
    }

    public static func decodeRecord(_ line: Data) throws -> HerdrTerminalBridgeRecord {
        guard
            let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = object["type"] as? String
        else { throw HerdrTerminalBridgeError.invalidRecord }
        switch type {
        case "terminal.frame":
            guard let encoded = object["bytes"] as? String,
                let bytes = Data(base64Encoded: encoded)
            else { throw HerdrTerminalBridgeError.invalidRecord }
            return .frame(bytes)
        case "terminal.closed":
            return .closed
        default:
            return .ignored
        }
    }

    public static func inputCommand(_ bytes: Data) throws -> Data {
        try command([
            "type": "terminal.input",
            "bytes": bytes.base64EncodedString(),
        ])
    }

    public static func resizeCommand(
        columns: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32
    ) throws -> Data {
        try command([
            "type": "terminal.resize",
            "cols": columns,
            "rows": rows,
            "cell_width_px": cellWidth,
            "cell_height_px": cellHeight,
        ])
    }

    private static func command(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
}
