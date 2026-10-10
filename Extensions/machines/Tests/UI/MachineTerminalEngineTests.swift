import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import GhosttyTerminal
import Foundation
import Testing

@testable import MachinesExtension

@Suite(.serialized) @MainActor struct MachineTerminalEngineTests {
    private func launch(_ command: String) -> MachinePTYLaunch {
        MachinePTYLaunch(
            executable: "/bin/sh", arguments: ["-c", command],
            environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
            currentDirectory: "/private/tmp", startupCommand: nil)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate())
    }

    @Test func realPTYInputResizeExitAndCheckedOwnershipRemainInEngine() async throws {
        let session = MachineSession(machine: .local, local: true, synthetic: true)
        let engine = MachineTerminalEngine(
            session: { _ in session },
            launch: { _, _ in
                launch(
                    "stty size; IFS= read -r value; printf 'received:%s\\n' \"$value\"; stty size; exit 7"
                )
            })
        var request = MachineTerminalRequest(
            operation: .open, machineID: session.id, columns: 104, rows: 35)
        request.presentationID = UUID()
        request.handle = try await engine.execute(request).handle
        request.operation = .read
        var bytes = Data()
        for _ in 0..<100 {
            let frame = try await engine.execute(request)
            bytes += frame.bytes; request.offset = frame.nextOffset
            if String(decoding: bytes, as: UTF8.self).contains("35 104") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(String(decoding: bytes, as: UTF8.self).contains("35 104"))
        var wrong = request; wrong.machineID = UUID()
        await #expect(throws: MachineUIError.self) { try await engine.execute(wrong) }
        wrong = request; wrong.tabID = UUID()
        await #expect(throws: MachineUIError.self) { try await engine.execute(wrong) }
        request.operation = .resize; request.columns = 83; request.rows = 29
        _ = try await engine.execute(request)
        request.operation = .input; request.bytes = Data("synthetic\n".utf8)
        _ = try await engine.execute(request)
        request.operation = .read
        var code: Int32?
        for _ in 0..<100 {
            let frame = try await engine.execute(request)
            bytes += frame.bytes; request.offset = frame.nextOffset; code = frame.exitCode
            if code != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(code == 7)
        #expect(String(decoding: bytes, as: UTF8.self).contains("received:synthetic"))
        #expect(String(decoding: bytes, as: UTF8.self).contains("29 83"))
        let presentation = try #require(request.presentationID)
        engine.release(presentation)
        request.operation = .read
        await #expect(throws: MachineUIError.self) { try await engine.execute(request) }
        await engine.shutdown()
        await #expect(throws: MachineUIError.self) { try await engine.execute(request) }
    }

    @Test func broadcastPreservesUnavailableAndNoOpenTabDiagnostics() async throws {
        let session = MachineSession(machine: .local, local: true, synthetic: true)
        let engine = MachineTerminalEngine(
            session: { _ in session }, launch: { _, _ in launch("exec cat") })
        var first = MachineTerminalRequest(operation: .open, machineID: session.id)
        let presentation = UUID()
        let group = UUID()
        let registration = MachineTerminalRequest(
            operation: .register, machineID: session.id, tabID: group, presentationID: presentation,
            tabIDs: [first.tabID, UUID()])
        _ = try await engine.execute(registration)
        first.handle = try await engine.execute(first).handle
        let plan = try MachineBroadcastOperationExecution.plan(command: "echo synthetic").get()
        let reply = try engine.broadcast(
            machineID: session.id, plan: plan, requestID: UUID().uuidString)
        #expect(reply[MachineTerminalBroadcastIPC.tabCountKey] as? Int == 1)
        #expect(reply[MachineTerminalBroadcastIPC.unavailableTabCountKey] as? Int == 1)
        #expect(
            reply[MachineTerminalBroadcastIPC.errorCodeKey] as? String
                == MachineTerminalBroadcastIPC.partialDeliveryCode)
        var hide = registration; hide.operation = .unregister
        _ = try await engine.execute(hide)
        let hidden = try engine.broadcast(
            machineID: session.id, plan: plan, requestID: UUID().uuidString)
        #expect(
            hidden[MachineTerminalBroadcastIPC.errorCodeKey] as? String
                == MachineTerminalBroadcastIPC.noOpenTabsCode)
        await engine.shutdown()
    }

    @Test func originalTTYCliRunsARealPTYAndPreservesOutputAndExit() async throws {
        let machine = Machine(name: "fixture-box", host: "fixture.invalid")
        let owner = MachineSession(machine: machine, synthetic: true)
        let engine = MachineTerminalEngine(
            session: { _ in owner },
            interactiveLaunch: { _, _, _ in
                launch(
                    "test -t 0 || exit 99; IFS= read -r value; printf 'terminal:%s' \"$value\"; exit 11"
                )
            })
        let previous = MachinesCLIEnvironment.interactive
        MachinesCLIEnvironment.interactive = { machine, arguments, environment in
            try await engine.runCLI(
                machine: machine, arguments: arguments, environment: environment)
        }
        defer { MachinesCLIEnvironment.interactive = previous }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = MachinePaths.root; MachinePaths.root = root
        defer { MachinePaths.root = old; try? FileManager.default.removeItem(at: root) }
        MachineRegistry.add(machine)
        let service = try MachineCLIService(runner: { machine, owner in
            RemoteRunner(machine: machine, owner: owner, connect: {})
        })
        let reply = try await service.execute(
            ExtensionCLIRequest(
                arguments: ["exec", "--tty", machine.name, "--", "fixture"],
                standardInput: Data("stdin-value\n".utf8)))
        #expect(reply.stdout == "terminal:stdin-value")
        #expect(reply.stderr.isEmpty)
        #expect(reply.exitCode == 11)
        await service.shutdown()
        await engine.shutdown()
    }

    @Test func originalHolderFeedsTheNativeRendererAndNativeInputReturnsToOwnedPTY() async throws {
        let owner = MachineSession(machine: .local, local: true, synthetic: true)
        let engine = MachineTerminalEngine(
            session: { _ in owner },
            launch: { _, _ in
                launch(
                    "stty icanon icrnl opost onlcr -echo; printf 'ready\\n'; IFS= read -r value; printf '\\033[32mowned:%s\\033[0m\\n' \"$value\"; printf '\\033]0;Machines fixture\\007'; exit 7"
                )
            })
        let bridge = MachineTerminalTestBridge(engine: engine)
        let client = MachineUIClient(
            client: try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID())))
        let session = MachineSession(machine: .local, local: true, uiClient: client)
        let holder = TerminalSessionHolder()
        holder.start(session: session)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isExcludedFromWindowsMenu = true
        let view = holder.retainedGhosttyView(
            theme: GhosttyTheme(background: "#000000", foreground: "#ffffff", cursor: "#ffffff"))
        view.frame = window.contentLayoutRect
        window.contentView = view
        defer { holder.stop(); window.contentView = nil; view.shutdown() }
        try await wait { (view.accessibilityValue() as? String)?.contains("ready") == true }
        #expect(view.insertText("synthetic-input\r"))
        try await wait { holder.exitMessage == "Session ended with status 7." }
        let screen = try #require(view.accessibilityValue() as? String)
        #expect(screen.contains("owned:synthetic-input"))
        #expect(!screen.contains("\u{1b}[32m"))
        #expect(holder.currentTitle == "Machines fixture")
        #expect(!view.receiveOutput(Data("stale".utf8)))
        #expect(session.connectionRef == nil)
        #expect(!window.isVisible)
        holder.stop()
        await engine.shutdown()
        client.shutdown()
    }
}

@MainActor private final class MachineTerminalTestBridge: NSObject {
    let engine: MachineTerminalEngine
    init(engine: MachineTerminalEngine) { self.engine = engine }

    @objc func invoke(_ data: NSData, completion: @escaping @Sendable (NSData) -> Void) {
        Task {
            do {
                let request = try ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data as Data)
                guard request.operation == "machines.ui.terminal" else {
                    throw MachineUIError.invalidRequest
                }
                let value = try JSONDecoder().decode(
                    MachineTerminalRequest.self, from: request.payload)
                let frame = try await engine.execute(value)
                let payload = try JSONEncoder().encode(
                    MachineUIReply(value: JSONEncoder().encode(frame), error: nil))
                completion(
                    try ExtensionEngineWire.encode(
                        ExtensionEngineReply(token: request.token, ok: true, payload: payload))
                        as NSData)
            } catch { Issue.record(error) }
        }
    }
    @objc func cancel(_ token: NSString) {}
    @objc func invalidate() {}
}
