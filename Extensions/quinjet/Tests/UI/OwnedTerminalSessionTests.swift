import AppKit
import Darwin
import EdithExtensionSupport
import Foundation
@testable import GhosttyTerminal
import Testing
@testable import QuinjetUI

@MainActor @Suite(.serialized) struct OwnedTerminalSessionTests {
    private func launch(_ command: String) -> OwnedTerminalLaunch {
        .init(
            executable: "/bin/sh", arguments: ["-c", command],
            environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
            currentDirectory: "/private/tmp", allowsLocalFileLinks: true,
            resetTerminalAfterInterrupt: false)
    }

    private func client(_ session: OwnedTerminalSession) throws -> OwnedTerminalClient {
        try OwnedTerminalClient(descriptor: session.descriptor) { operation, payload in
            try await session.execute(operation, payload: payload)
        }
    }

    @Test func actualOwnedPTYPreservesInputResizeUTF8TermiosAndExit() async throws {
        let session = try OwnedTerminalSession(
            launch: launch(
                "stty icanon -echo; printf 'ready:'; read value; printf '\\033[32m%s ☃\\033[0m:' \"$value\"; stty size; exit 7"
            ))
        defer { session.stop() }
        let client = try client(session)
        defer { client.stop() }
        var offset: UInt64 = 0
        var bytes = Data()
        var canonical = false
        for _ in 0..<100 {
            let output = try await client.read(after: offset)
            offset = output.nextOffset
            bytes.append(output.bytes)
            if String(decoding: bytes, as: UTF8.self).contains("ready:") {
                canonical = output.canonical && !output.echo
                break
            }
        }
        #expect(canonical)
        try await client.resize(columns: 101, rows: 37)
        try await client.input(Data("fixture-input\n".utf8))
        var exit: Int32?
        for _ in 0..<100 {
            let output = try await client.read(after: offset)
            offset = output.nextOffset
            bytes.append(output.bytes)
            if let code = output.exitCode { exit = code; break }
        }
        #expect(exit == 7)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("fixture-input ☃") && text.contains("37 101"))
        #expect(try await client.read(after: 0).bytes == bytes)
    }

    @Test func originalNativeRendererUsesEngineIOAndRetainsFinalScreenUntilReset() async throws {
        let holder = TerminalSessionHolder()
        holder.start(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "read value; printf '\\033[32m%s ☃\\033[0m' \"$value\"; exit 7",
            ],
            environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
            currentDirectory: "/private/tmp")
        let view = holder.retainedGhosttyView(theme: .init(palette: .edith(dark: true)))
        let window = TestWindowHost.window(contentRect: .init(x: 0, y: 0, width: 640, height: 400))
        view.frame = window.contentLayoutRect
        window.contentView = view
        defer { holder.stop(); window.contentView = nil }
        for _ in 0..<20 {
            if view.insertText("fixture-input") {
                let event = try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "\r",
                        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                view.keyDown(with: event)
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<200 {
            if holder.exitMessage != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(holder.exitMessage == "Session ended with status 7.")
        #expect(holder.ghosttyView === view && holder.started)
        #expect(view.performBindingAction("select_all"))
        #expect(view.selectedText()?.contains("fixture-input ☃") == true)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        holder.reset()
        #expect(holder.ghosttyView == nil && holder.descriptor == nil && !holder.started)
        #expect(!view.receiveOutput(Data("stale".utf8)))
    }

    @Test func capabilitiesAreOwnerBoundAndCloseReapsOnlyOwnedChild() async throws {
        let session = try OwnedTerminalSession(launch: launch("printf '%s' $$; exec cat"))
        defer { session.stop() }
        let client = try client(session)
        let output = try await client.read(after: 0)
        let pid = try #require(Int32(String(decoding: output.bytes, as: UTF8.self)))
        #expect(kill(pid, 0) == 0)
        let valid = session.descriptor.handle
        for handle in [
            OwnedTerminalHandle(owner: "wrong", id: valid.id, generation: valid.generation),
            OwnedTerminalHandle(owner: valid.owner, id: UUID(), generation: valid.generation),
            OwnedTerminalHandle(owner: valid.owner, id: valid.id, generation: UUID()),
        ] {
            await #expect(throws: ExtensionPeerError.self) {
                try await session.execute(
                    "quinjet.terminal.read",
                    payload: JSONEncoder().encode(
                        OwnedTerminalRequest(session: handle, offset: 0)))
            }
        }
        let injection = try JSONSerialization.data(withJSONObject: [
            "session": [
                "owner": valid.owner, "id": valid.id.uuidString,
                "generation": valid.generation.uuidString,
            ],
            "offset": 0, "executable": "/bin/sh",
        ])
        await #expect(throws: ExtensionPeerError.self) {
            try await session.execute("quinjet.terminal.read", payload: injection)
        }
        try await client.close()
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        await #expect(throws: ExtensionPeerError.self) { try await client.read(after: 0) }
    }

    @Test func cancelledClientRejectsLateRepliesAndInvalidOutputCursors() async throws {
        let descriptor = OwnedTerminalDescriptor(
            handle: .init(owner: "quinjet", id: UUID(), generation: UUID()),
            directory: "/private/tmp",
            allowsLocalFileLinks: true, resetTerminalAfterInterrupt: false)
        var pending: CheckedContinuation<Data, Error>?
        let client = try OwnedTerminalClient(descriptor: descriptor) { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        let read = Task { try await client.read(after: 0) }
        while pending == nil { await Task.yield() }
        client.stop()
        pending?.resume(
            returning: try JSONEncoder().encode(
                OwnedTerminalPTY.Output(
                    bytes: Data([65]), nextOffset: 1, exitCode: nil, canonical: false, echo: true)))
        await #expect(throws: CancellationError.self) { try await read.value }
        let invalid = try OwnedTerminalClient(descriptor: descriptor) { _, _ in
            try JSONEncoder().encode(
                OwnedTerminalPTY.Output(
                    bytes: Data([65]), nextOffset: 2, exitCode: nil, canonical: false, echo: true))
        }
        await #expect(throws: ExtensionPeerError.self) { try await invalid.read(after: 0) }
        invalid.stop()
    }
}
