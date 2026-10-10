import AppKit
import EdithExtensionSupport
import Foundation
@testable import GhosttyTerminal
import Testing
@testable import QuinjetUI

@MainActor @Suite(.serialized) struct OwnedTerminalFilesTests {
    private func session(_ registry: OwnedTerminalSessionRegistry, local: Bool = true) throws
        -> OwnedTerminalSession
    {
        try OwnedTerminalContext.$registry.withValue(registry) {
            try OwnedTerminalSession(
                launch: .init(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "stty icanon -echo; printf ready; IFS= read -r value; printf 'accepted:%s' \"$value\"; exit 7",
                    ], environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
                    currentDirectory: "/private/tmp", allowsLocalFileLinks: local,
                    resetTerminalAfterInterrupt: false))
        }
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "owned-drop-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test func rawNativeMediaBytesStayBinaryAndAreMaterializedOnlyByOwningEngine() async throws {
        let registry = OwnedTerminalSessionRegistry()
        defer { registry.stopAll() }
        let terminal = try session(registry)
        let bridge = SyntheticPTYEngineBridge(registry: registry)
        let sdk = try #require(
            ExtensionEngineClient(bridge: bridge, presentationID: bridge.presentation))
        defer { sdk.invalidate() }
        let client = try OwnedTerminalClient(descriptor: terminal.descriptor) {
            try await sdk.invoke($0, payload: $1)
        }
        let bytes = Data((0..<65539).map { UInt8(truncatingIfNeeded: $0) })
        let paths = try await client.uploadBytes(bytes, name: "synthetic-media.bin")
        #expect(
            paths.count == 1 && paths[0].contains("edith-" + OwnedTerminalSession.owner + "-drop-"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == bytes)
        await registry.stopAllAndWait()
        #expect(!FileManager.default.fileExists(atPath: paths[0]))
    }

    @Test func stalePromiseDeliveryCannotUploadIntoAReboundTerminal() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.bin")
        try Data([0, 255]).write(to: source)
        let registry = OwnedTerminalSessionRegistry()
        defer { registry.stopAll() }
        let old = try session(registry)
        let current = try session(registry)
        let holder = TerminalSessionHolder()
        holder.bind(
            try OwnedTerminalClient(descriptor: old.descriptor) {
                try await old.execute($0, payload: $1)
            })
        let generation = holder.generation
        holder.reset()
        var invocations = 0
        holder.bind(
            try OwnedTerminalClient(descriptor: current.descriptor) { operation, payload in
                invocations += 1; return try await current.execute(operation, payload: payload)
            })
        #expect(
            holder.handleDropFiles(
                .init(files: [source], temporaryFiles: [source]), generation: generation))
        #expect(
            invocations == 0 && holder.descriptor == current.descriptor && !holder.transferringDrop)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        holder.stopRendering()
        await registry.stopAllAndWait()
    }

    @Test func actualSDKCopiesBinaryAndEmptyFilesIntoOwningEngineAndCleansOnClose() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("synthetic x'y.bin")
        let empty = root.appendingPathComponent("empty.txt")
        let bytes = Data((0..<65539).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: first); try Data().write(to: empty)
        let registry = OwnedTerminalSessionRegistry()
        defer { registry.stopAll() }
        let terminal = try session(registry)
        let bridge = SyntheticPTYEngineBridge(registry: registry)
        let sdk = try #require(
            ExtensionEngineClient(bridge: bridge, presentationID: bridge.presentation))
        defer { sdk.invalidate() }
        let client = try OwnedTerminalClient(descriptor: terminal.descriptor) {
            try await sdk.invoke($0, payload: $1)
        }
        let paths = try await client.uploadFiles([first, empty])
        #expect(paths.count == 2 && paths[0] != first.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == bytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[1])).isEmpty)
        #expect(
            try FileManager.default.attributesOfItem(atPath: paths[0])[.posixPermissions] as? Int
                == 0o600)
        #expect(try Data(contentsOf: first) == bytes)
        try await client.close()
        #expect(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        await registry.stopAllAndWait()
    }

    @Test func originalNativeDropPasteUsesEngineCopiedPromiseAndRetainsQuotedUTF8ExitOutput()
        async throws
    {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic café x'y.bin")
        let bytes = Data([0, 255, 128, 1, 2])
        try bytes.write(to: source)
        let registry = OwnedTerminalSessionRegistry()
        defer { registry.stopAll() }
        let terminal = try session(registry)
        let holder = TerminalSessionHolder()
        let client = try OwnedTerminalClient(descriptor: terminal.descriptor) {
            try await terminal.execute($0, payload: $1)
        }
        holder.bind(client)
        let view = holder.retainedGhosttyView(theme: .init(palette: .edith(dark: true)))
        let window = TestWindowHost.window(contentRect: .init(x: 0, y: 0, width: 640, height: 400))
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = window.contentLayoutRect
        defer { holder.stopRendering(); window.contentView = nil; window.close() }
        for _ in 0..<300 {
            _ = view.performBindingAction("select_all")
            if view.selectedText()?.contains("ready") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(holder.handleDropFiles(.init(files: [source], temporaryFiles: [source])))
        for _ in 0..<300 {
            if !holder.transferringDrop { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!holder.transferringDrop && holder.dropTransferError == nil)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        view.keyDown(with: event)
        for _ in 0..<300 {
            if holder.exitMessage != nil { break }; try await Task.sleep(for: .milliseconds(10))
        }
        #expect(holder.exitMessage == "Session ended with status 7.")
        #expect(view.performBindingAction("select_all"))
        let text = try #require(view.selectedText())
        #expect(text.contains("accepted:") && text.contains("synthetic café x"))
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        await registry.stopAllAndWait()
    }

    @Test func engineValidatesDropOwnerOffsetsAndReplayWithoutRepeatingFileServices() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = OwnedTerminalSessionRegistry()
        defer { registry.stopAll() }
        let terminal = try session(registry, local: false)
        var services = 0
        registry.files.upload = { _, files in
            services += 1
            let destination = root.appendingPathComponent("service-receipt.bin")
            try FileManager.default.copyItem(at: files[0], to: destination)
            return [destination.path]
        }
        let client = try OwnedTerminalClient(descriptor: terminal.descriptor) {
            try await terminal.execute($0, payload: $1)
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await client.fileRequest(
                "begin", .init(session: terminal.descriptor.handle, names: ["../escape"]))
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await client.fileRequest(
                "paths",
                .init(session: terminal.descriptor.handle, paths: ["/tmp/injected-local-file"]))
        }
        let begun = try await client.fileRequest(
            "begin", .init(session: terminal.descriptor.handle, names: ["synthetic.bin"]))
        let token = try #require(begun.token)
        let data = Data([0, 255, 128, 1])
        await #expect(throws: ExtensionPeerError.self) {
            try await client.fileRequest(
                "write",
                .init(
                    session: terminal.descriptor.handle, token: token, index: 0, offset: 1,
                    bytes: data))
        }
        _ = try await client.fileRequest(
            "write",
            .init(
                session: terminal.descriptor.handle, token: token, index: 0, offset: 0, bytes: data)
        )
        let other = try session(registry, local: false)
        await #expect(throws: ExtensionPeerError.self) {
            try await other.execute(
                "quinjet.terminal.drop.finish",
                payload: JSONEncoder().encode(
                    OwnedTerminalDropRequest(session: other.descriptor.handle, token: token)))
        }
        var receipt = try await client.fileRequest(
            "finish", .init(session: terminal.descriptor.handle, token: token))
        for _ in 0..<100 where receipt.state == "running" {
            try await Task.sleep(for: .milliseconds(1));
            receipt = try await client.fileRequest(
                "status", .init(session: terminal.descriptor.handle, token: token))
        }
        #expect(receipt.state == "complete" && services == 1)
        let replay = try await client.fileRequest(
            "finish", .init(session: terminal.descriptor.handle, token: token))
        #expect(replay.paths == receipt.paths && services == 1)
        #expect(try Data(contentsOf: root.appendingPathComponent("service-receipt.bin")) == data)
        await registry.stopAllAndWait()
    }

    @Test func disablingOwnerCancelsAndDrainsPendingFileServiceAndDeletesOnlyItsCopies()
        async throws
    {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.bin")
        try Data([0, 255]).write(to: source)
        let registry = OwnedTerminalSessionRegistry()
        defer { registry.stopAll() }
        let terminal = try session(registry, local: false)
        var started = false
        var stopped = false
        var copied: [URL] = []
        registry.files.upload = { _, files in
            copied = files; started = true
            defer { stopped = true }
            try await Task.sleep(for: .seconds(30))
            return files.map(\.path)
        }
        let client = try OwnedTerminalClient(descriptor: terminal.descriptor) {
            try await terminal.execute($0, payload: $1)
        }
        let transfer = Task { try await client.uploadFiles([source]) }
        for _ in 0..<300 { if started { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(started && copied.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        await registry.stopAllAndWait()
        transfer.cancel()
        await #expect(throws: (any Error).self) { try await transfer.value }
        #expect(stopped && copied.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try Data(contentsOf: source) == Data([0, 255]))
    }
}
