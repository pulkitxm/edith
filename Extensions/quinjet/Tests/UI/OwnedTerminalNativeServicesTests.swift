import EdithExtensionSupport
import Foundation
import GhosttyTerminal
import Testing

@testable import QuinjetUI

@MainActor @Suite(.serialized) struct OwnedTerminalNativeServicesTests {
    @Test func mediaCallbackTransfersExactBinaryBytesToOwningEngineAndRetiresFiles() async throws {
        let registry = OwnedTerminalSessionRegistry()
        defer { registry.stopAll() }
        let session = try terminal(registry, local: true)
        let holder = TerminalSessionHolder()
        var paths: [String] = []
        holder.bind(
            try OwnedTerminalClient(descriptor: session.descriptor) { operation, payload in
                let reply = try await session.execute(operation, payload: payload)
                if operation.hasSuffix(".drop.finish") || operation.hasSuffix(".drop.status") {
                    paths =
                        try JSONDecoder().decode(OwnedTerminalDropReceipt.self, from: reply).paths
                        ?? []
                }
                return reply
            })
        let bytes = Data((0..<32771).map { UInt8(truncatingIfNeeded: $0) })
        #expect(
            holder.handleDropFiles(
                .init(files: [], media: .init(data: bytes, fileExtension: "png"))))
        for _ in 0..<400 {
            if !holder.transferringDrop { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(
            !holder.transferringDrop && holder.dropTransferError == nil && holder.hasQueuedInput)
        let path = try #require(paths.first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(path.hasSuffix("drop.png"))
        holder.stopRendering()
        await registry.stopAllAndWait()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func checkedLinkResolutionRequiresSameLiveSessionSingleUseAndExpiry() async throws {
        let registry = OwnedTerminalSessionRegistry()
        defer { registry.stopAll() }
        var opened: [URL] = []
        var date = Date()
        registry.links.open = {
            opened.append($0); return true
        }
        registry.links.handler = { _ in "Synthetic handler" }
        registry.links.now = { date }
        let session = try terminal(registry)
        let other = try terminal(registry)
        let bridge = SyntheticPTYEngineBridge(registry: registry)
        let sdk = try #require(
            ExtensionEngineClient(bridge: bridge, presentationID: bridge.presentation))
        defer { sdk.invalidate() }
        let client = try OwnedTerminalClient(descriptor: session.descriptor) {
            try await sdk.invoke($0, payload: $1)
        }
        let foreign = try OwnedTerminalClient(descriptor: other.descriptor) {
            try await sdk.invoke($0, payload: $1)
        }
        let allowed = try await client.resolveLink(
            "https://example.invalid/synthetic", untrusted: false)
        #expect(allowed.resolution.disposition == .allow && opened.isEmpty)
        let token = try #require(allowed.token)
        await #expect(throws: ExtensionEngineError.self) { try await foreign.openLink(token) }
        try await client.openLink(token)
        #expect(opened.map(\.absoluteString) == ["https://example.invalid/synthetic"])
        await #expect(throws: ExtensionEngineError.self) { try await client.openLink(token) }
        let denied = try await client.resolveLink("http:///synthetic", untrusted: true)
        #expect(denied.resolution.disposition == .deny && denied.token == nil)
        let local = try await client.resolveLink("file:///tmp/synthetic", untrusted: true)
        #expect(local.resolution.disposition == .deny && local.token == nil)
        let confirm = try await client.resolveLink("synthetic-protocol://fixture", untrusted: true)
        #expect(
            confirm.resolution.disposition == .confirm
                && confirm.resolution.detail.contains("Synthetic handler"))
        let expired = try #require(confirm.token)
        date += 61
        await #expect(throws: ExtensionEngineError.self) { try await client.openLink(expired) }
        let current = try #require(
            try await client.resolveLink("https://example.invalid/next", untrusted: false).token)
        session.stop()
        await #expect(throws: ExtensionEngineError.self) { try await client.openLink(current) }
        #expect(opened.count == 1)
        await registry.stopAllAndWait()
    }

    private func terminal(_ registry: OwnedTerminalSessionRegistry, local: Bool = false) throws
        -> OwnedTerminalSession
    {
        try OwnedTerminalContext.$registry.withValue(registry) {
            try OwnedTerminalSession(
                launch: .init(
                    executable: "/bin/sh", arguments: ["-c", "exec sleep 30"],
                    environment: ["PATH=/usr/bin:/bin"], currentDirectory: "/tmp",
                    allowsLocalFileLinks: local, resetTerminalAfterInterrupt: false))
        }
    }
}
