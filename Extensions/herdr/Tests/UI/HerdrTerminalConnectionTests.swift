import Darwin
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Testing
@testable import HerdrUI

@MainActor @Suite(.serialized) struct HerdrTerminalConnectionTests {
    @Test func originalSpaceShellConnectsThroughOwnedEngineAndCloseRetiresItsCapability()
        async throws
    {
        defer { HerdrWorkOwnership.enable() }
        let suite = "herdr.connections.fixture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engineStore = HerdrStore(defaults: defaults, machinesProvider: { [] })
        let worker = HerdrWorker(
            store: engineStore, defaults: defaults, automaticActions: false,
            prepareShell: { _, _ in
                .init(
                    executable: "/bin/sh", arguments: ["-c", "printf '%s' $$; exec cat"],
                    environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"])
            })
        let uiStore = HerdrStore(defaults: defaults, machinesProvider: { [] })
        uiStore.terminalClient = { try await worker.execute($0, payload: $1) }
        let paneID = UUID()
        let holder = TerminalSessionHolder()
        let target = PaneTarget(
            machineID: Machine.localID, screen: .terminal, argument: "/private/tmp")
        try await uiStore.connectShell(holder, paneID: paneID, target: target)
        let descriptor = try #require(holder.descriptor)
        #expect(holder.terminalLaunch == nil && descriptor.handle.owner == "herdr")
        let transport = try OwnedTerminalClient(descriptor: descriptor) {
            try await worker.execute($0, payload: $1)
        }
        let first = try await transport.read(after: 0)
        let pid = try #require(Int32(String(decoding: first.bytes, as: UTF8.self)))
        try await transport.resize(columns: 101, rows: 37)
        try await transport.input(Data("fixture-input\n".utf8))
        let reply = try await transport.read(after: first.nextOffset)
        #expect(String(decoding: reply.bytes, as: UTF8.self).contains("fixture-input"))
        holder.stopRendering()
        #expect(kill(pid, 0) == 0)
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute(
                "herdr.shell.open",
                payload: JSONSerialization.data(withJSONObject: [
                    "paneID": paneID.uuidString, "machineID": Machine.localID.uuidString,
                    "directory": "/private/tmp", "executable": "/bin/sh",
                ]))
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute(
                "herdr.shell.open",
                payload: JSONSerialization.data(withJSONObject: [
                    "paneID": paneID.uuidString, "machineID": Machine.localID.uuidString,
                    "directory": "/private/tmp/different",
                ]))
        }
        try await transport.close()
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute(
                "herdr.terminal.read",
                payload: JSONEncoder().encode(
                    OwnedTerminalRequest(session: descriptor.handle, offset: 0)))
        }
        try await uiStore.connectShell(holder, paneID: paneID, target: target)
        #expect(holder.descriptor?.handle != descriptor.handle && holder.terminalLaunch == nil)
        await uiStore.shutdown()
        await worker.shutdown()
        holder.stopRendering()
    }

    @Test func resetWhileAnOwnerReplyIsPendingCannotRestoreTheRendererSession() async throws {
        let suite = "herdr.connections.fixture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HerdrStore(defaults: defaults, machinesProvider: { [] })
        let holder = TerminalSessionHolder()
        let descriptor = OwnedTerminalDescriptor(
            handle: .init(owner: "herdr", id: UUID(), generation: UUID()),
            directory: "/private/tmp", allowsLocalFileLinks: false,
            resetTerminalAfterInterrupt: false)
        var continuation: CheckedContinuation<Data, Error>?
        store.terminalClient = { operation, payload in
            #expect(operation == "herdr.shell.open")
            let object = try #require(
                try JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect(Set(object.keys) == ["paneID", "machineID", "directory"])
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let pending = Task {
            try await store.connectShell(
                holder, paneID: UUID(),
                target: .init(
                    machineID: Machine.localID, screen: .terminal, argument: "/private/tmp"))
        }
        while continuation == nil { await Task.yield() }
        holder.stopRendering()
        continuation?.resume(returning: try JSONEncoder().encode(descriptor))
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(
            holder.descriptor == nil && holder.terminalLaunch == nil && holder.ghosttyView == nil)
        await store.shutdown()
    }
}
