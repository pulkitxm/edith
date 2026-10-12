import DatabaseMCP
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

enum DatabaseCLIMCP {
    static func run() async throws {
        guard let resources = DatabaseCLIEnvironment.resources,
            let request = ExtensionCLIContext.request
        else { throw ExtensionPeerError.unavailable }
        let read: @Sendable () async throws -> Data?
        if let input = ExtensionCLIContext.input {
            read = {
                while let event = try await input.read() {
                    switch event {
                    case .bytes(let bytes): return bytes
                    case .resize: continue
                    }
                }
                return nil
            }
        } else {
            let input = DatabaseFiniteCLIInput(request.standardInput)
            read = { await input.read() }
        }
        let transport = DatabaseMCPByteTransport(
            read: read,
            write: { data in
                var offset = 0
                while offset < data.count {
                    try Task.checkCancellation()
                    let end = min(offset + 16_384, data.count)
                    try CLIOut.raw(data.subdata(in: offset..<end))
                    offset = end
                    await Task.yield()
                }
            })
        try await DatabaseMCPServer(sender: resources.sender).run(transport: transport)
    }
}

private actor DatabaseFiniteCLIInput {
    private var data: Data
    private var offset = 0
    init(_ data: Data) { self.data = data }
    func read() -> Data? {
        guard offset < data.count else { return nil }
        let end = min(offset + 16_384, data.count)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
}
