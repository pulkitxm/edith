import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum OwnedTerminalCLI {
    static func run(
        _ request: TerminalLaunchRequest, directory: String? = nil, errorOutput: Bool = false
    ) async throws -> Int32 {
        guard OwnedTerminalContext.registry != nil, let input = ExtensionCLIContext.input else {
            throw CLIFailure.unavailable(
                "Foreground terminal input requires the owning CLI stream.")
        }
        let session = try OwnedTerminalSession(
            launch: .init(
                executable: request.executable, arguments: request.arguments,
                environment: request.environment,
                currentDirectory: directory ?? ExtensionCLIContext.request?.workingDirectory ?? "/",
                allowsLocalFileLinks: false, resetTerminalAfterInterrupt: false))
        defer { session.stop() }
        let client = try OwnedTerminalClient(descriptor: session.descriptor) {
            try await session.execute($0, payload: $1)
        }
        defer { client.stop() }
        return try await withThrowingTaskGroup(of: Int32?.self) { group in
            group.addTask {
                while let event = try await input.read() {
                    switch event {
                    case .bytes(let bytes): try await client.input(bytes)
                    case .resize(let columns, let rows):
                        try await client.resize(columns: UInt16(columns), rows: UInt16(rows))
                    }
                }
                try await client.input(Data([4]))
                return nil
            }
            group.addTask {
                var cursor: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    let frame = try await client.read(after: cursor)
                    try CLIOut.raw(frame.bytes, error: errorOutput)
                    cursor = frame.nextOffset
                    if let code = frame.exitCode { return code }
                }
            }
            while let result = try await group.next() {
                if let status = result { group.cancelAll(); return status }
            }
            throw ExtensionPeerError.unavailable
        }
    }
}
