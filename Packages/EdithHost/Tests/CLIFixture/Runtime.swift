import ArgumentParser
import EdithExtensionCommands
import EdithExtensionArchive
import EdithExtensionSupport
import Foundation

@MainActor @objc(EdithCLIFixtureRuntime)
final class CLIFixtureRuntime: NSObject {
    private let commands = ExtensionCommandRegistry()
    private let streams = try! ExtensionCLIStreams(owner: "keepAwake")

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { operation, payload in
            switch operation {
            case "calendar.cli.catalog":
                return try JSONSerialization.data(withJSONObject: [
                    "version": 1, "owner": "calendar", "acceptsInput": true,
                    "commands": [
                        "list", "ls", "synthetic-error", "context", "wait", "stream", "stream-wait",
                        "stream-input", "stream-terminal", "stream-mcp",
                    ].map { command in
                        var value: [String: Any] = [
                            "route": ["calendar", command], "operation": "calendar.cli",
                            "summary": "Exercise the synthetic signed CLI protocol.",
                            "destructive": false, "timeout": 30,
                            "readsInput": command == "context"
                                || ["stream-input", "stream-terminal", "stream-mcp"].contains(
                                    command),
                            "jsonOutput": !command.hasPrefix("stream"),
                        ]
                        if command.hasPrefix("stream") {
                            value["streamOperation"] = "calendar.cli.stream"
                            value["streamDeadline"] = 30
                        }
                        return value
                    }, "settings": [],
                ])
            case "calendar.cli":
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    await ExtensionCLIExecution.run(CalendarFixtureRoot.self, request: request))
            case "calendar.cli.stream.start", "calendar.cli.stream.read",
                "calendar.cli.stream.cancel", "calendar.cli.stream.end",
                "calendar.cli.stream.write", "calendar.cli.stream.resize":
                return try self.streams.invoke(
                    CalendarFixtureRoot.self, operation: operation, prefix: "calendar.cli.stream",
                    payload: payload)
            case "echo": return payload
            case "archive":
                guard
                    let input = try JSONSerialization.jsonObject(with: payload)
                        as? [String: String],
                    let encoded = input["archive"], let archive = Data(base64Encoded: encoded),
                    let contents = try ArchiveFileReader.read(
                        named: "fixture.txt", from: archive, maximumBytes: 128),
                    let text = String(data: contents, encoding: .utf8)
                else { throw ExtensionPeerError.rejected("Invalid archive fixture.") }
                return try JSONSerialization.data(withJSONObject: ["text": text])
            case "wait":
                let marker = ExtensionData.root.appendingPathComponent("wait.ready")
                try Data("ready".utf8).write(to: marker, options: .atomic)
                defer { try? FileManager.default.removeItem(at: marker) }
                try await Task.sleep(for: .seconds(30))
                return payload
            case "blockUI":
                let marker = ExtensionData.root.appendingPathComponent("ui.ready")
                try Data("ready".utf8).write(to: marker, options: .atomic)
                Thread.sleep(forTimeInterval: 1.5)
                try? FileManager.default.removeItem(at: marker)
                return Data("{\"finished\":true}".utf8)
            default: throw ExtensionPeerError.rejected("Unknown fixture operation.")
            }
        }
    }

    @objc(prepareToStopWithCompletion:) func prepareToStop(completion: @escaping () -> Void) {
        Task {
            await commands.shutdownAndWait(); await streams.stopAndWait(); completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            return [
                "id": "keepAwake", "version": "VERSION", "hostABI": "edith-host-2",
                "role": "helper",
            ] as NSDictionary
        case "start":
            do {
                try FileManager.default.createDirectory(
                    at: ExtensionData.root, withIntermediateDirectories: true)
                return ["ok": true] as NSDictionary
            } catch { return ["ok": false] as NSDictionary }
        case "status": return ["ok": true] as NSDictionary
        case "cancelCommand":
            commands.cancel(input["token"] as? String ?? "")
            return ["ok": true] as NSDictionary
        case "stop":
            commands.shutdown(); streams.stop()
            return ["ok": true] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
    }
}

@_cdecl("edith_extension_create")
public func createCLIFixture() -> UnsafeMutableRawPointer? {
    let address = MainActor.assumeIsolated {
        UInt(bitPattern: Unmanaged.passRetained(CLIFixtureRuntime()).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)
}

struct CalendarFixtureRoot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        subcommands: [
            List.self, Failure.self, Context.self, Wait.self, Stream.self, StreamWait.self,
            StreamInput.self, StreamTerminal.self, StreamMCP.self,
        ],
        defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", aliases: ["ls"])
        @Flag var json = false
        func run() async throws {
            let arguments = try JSONSerialization.data(
                withJSONObject: ExtensionCLIContext.request!.arguments)
            CLIOut.out(String(decoding: arguments, as: UTF8.self))
        }
    }

    struct Failure: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "synthetic-error")
        @Flag var json = false
        func run() async throws { CLIOut.note("error: synthetic unavailable"); throw ExitCode(4) }
    }

    struct Context: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "context")
        @Flag var json = false
        @Argument var path: String
        func run() async throws {
            let request = try await CLIFixtureContext.request()
            let file = try ExtensionCLIContext.resolvePath(path)
            let content = try String(contentsOf: file, encoding: .utf8)
            let value: [String: Any] = [
                "workingDirectory": request.workingDirectory,
                "input": request.standardInput.base64EncodedString(),
                "interactive": request.interactive, "file": file.path, "content": content,
            ]
            CLIOut.out(
                String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
        }
    }

    struct Wait: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "wait")
        @Flag var json = false
        func run() async throws { try await CLIFixtureContext.wait() }
    }

    struct Stream: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "stream")
        func run() async throws {
            CLIOut.raw("first\0🌤\n")
            try await Task.sleep(for: .milliseconds(75))
            CLIOut.note("synthetic diagnostic")
            CLIOut.out("last")
            throw ExitCode(7)
        }
    }

    struct StreamInput: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "stream-input")
        func run() async throws {
            guard let input = ExtensionCLIContext.input else {
                throw ExtensionPeerError.invalidRequest
            }
            while let event = try await input.read() {
                switch event {
                case .bytes(let data): try CLIOut.raw(data)
                case .resize(let columns, let rows): CLIOut.note("resize=\(columns)x\(rows)")
                }
            }
            CLIOut.note("eof")
        }
    }

    struct StreamTerminal: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "stream-terminal")
        @Option var count: Int = 0
        func run() async throws {
            guard let input = ExtensionCLIContext.input else {
                throw ExtensionPeerError.invalidRequest
            }
            let request = try await CLIFixtureContext.request()
            CLIOut.note("interactive=\(request.interactive)")
            var received = 0
            while let event = try await input.read() {
                switch event {
                case .bytes(let data):
                    try CLIOut.raw(data); received += data.count
                    if count > 0, received >= count { return }
                case .resize(let columns, let rows): CLIOut.note("resize=\(columns)x\(rows)")
                }
            }
        }
    }

    struct StreamMCP: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "stream-mcp")
        func run() async throws {
            guard let input = ExtensionCLIContext.input else {
                throw ExtensionPeerError.invalidRequest
            }
            var buffer = Data()
            while let event = try await input.read() {
                guard case .bytes(let bytes) = event else {
                    throw ExtensionPeerError.invalidRequest
                }
                buffer.append(bytes)
                while let newline = buffer.firstIndex(of: 10) {
                    let frame = Data(buffer.prefix(upTo: newline))
                    buffer.removeSubrange(...newline)
                    guard frame.count <= 512 * 1024,
                        let object = try JSONSerialization.jsonObject(with: frame)
                            as? [String: Any],
                        object["jsonrpc"] as? String == "2.0", let id = object["id"],
                        let method = object["method"] as? String
                    else { throw ExtensionPeerError.invalidRequest }
                    let response: [String: Any] = [
                        "jsonrpc": "2.0", "id": id,
                        "result": ["method": method, "params": object["params"] ?? [:]],
                    ]
                    var output = try JSONSerialization.data(
                        withJSONObject: response, options: [.sortedKeys])
                    output.append(10); try CLIOut.raw(output)
                }
                guard buffer.count <= 512 * 1024 else { throw ExtensionPeerError.invalidRequest }
            }
            guard buffer.isEmpty else { throw ExtensionPeerError.invalidRequest }
        }
    }

    struct StreamWait: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "stream-wait")
        func run() async throws { try await CLIFixtureContext.wait() }
    }
}

@MainActor private enum CLIFixtureContext {
    static func request() throws -> ExtensionCLIRequest {
        guard let request = ExtensionCLIContext.request else {
            throw ExtensionPeerError.invalidRequest
        }
        return request
    }
    static func wait() async throws {
        let marker = ExtensionData.root.appendingPathComponent("cli-wait.ready")
        try Data("ready".utf8).write(to: marker, options: .atomic)
        defer { try? FileManager.default.removeItem(at: marker) }
        try await Task.sleep(for: .seconds(30))
        try Task.checkCancellation()
        CLIOut.out("finished")
    }
}
