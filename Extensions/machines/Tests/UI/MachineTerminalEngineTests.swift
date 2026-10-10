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
        let reply = try await engine.broadcast(
            machineID: session.id, plan: plan, requestID: UUID().uuidString)
        #expect(reply[MachineTerminalBroadcastIPC.tabCountKey] as? Int == 1)
        #expect(reply[MachineTerminalBroadcastIPC.unavailableTabCountKey] as? Int == 1)
        #expect(
            reply[MachineTerminalBroadcastIPC.errorCodeKey] as? String
                == MachineTerminalBroadcastIPC.partialDeliveryCode)
        var hide = registration; hide.operation = .unregister
        _ = try await engine.execute(hide)
        let hidden = try await engine.broadcast(
            machineID: session.id, plan: plan, requestID: UUID().uuidString)
        #expect(
            hidden[MachineTerminalBroadcastIPC.errorCodeKey] as? String
                == MachineTerminalBroadcastIPC.noOpenTabsCode)
        await engine.shutdown()
    }

    @Test func originalLongBroadcastDeliversEveryByteThroughBoundedPTYChunks() async throws {
        let session = MachineSession(machine: .local, local: true, synthetic: true)
        let plan = try MachineBroadcastOperationExecution.plan(
            command: String(repeating: "synthetic", count: 4096)
        ).get()
        let count = plan.terminalInput.utf8.count
        let engine = MachineTerminalEngine(
            session: { _ in session },
            launch: { _, _ in
                launch("stty raw -echo; printf ready; dd bs=1 count=\(count) 2>/dev/null | wc -c")
            })
        let presentation = UUID()
        var request = MachineTerminalRequest(
            operation: .open, machineID: session.id, presentationID: presentation)
        let registration = MachineTerminalRequest(
            operation: .register, machineID: session.id, tabID: UUID(),
            presentationID: presentation, tabIDs: [request.tabID])
        _ = try await engine.execute(registration)
        request.handle = try await engine.execute(request).handle
        request.operation = .read
        var output = Data()
        for _ in 0..<100 {
            let frame = try await engine.execute(request)
            output += frame.bytes; request.offset = frame.nextOffset
            if String(decoding: output, as: UTF8.self).contains("ready") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(String(decoding: output, as: UTF8.self).contains("ready"))
        let reply = try await engine.broadcast(
            machineID: session.id, plan: plan, requestID: UUID().uuidString)
        #expect(reply[MachineTerminalBroadcastIPC.okKey] as? Bool == true)
        var code: Int32?
        for _ in 0..<300 {
            let frame = try await engine.execute(request)
            output += frame.bytes; request.offset = frame.nextOffset; code = frame.exitCode
            if code != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(code == 0)
        #expect(String(decoding: output, as: UTF8.self).contains(String(count)))
        #expect(!String(decoding: output, as: UTF8.self).contains("synthetic"))
        await engine.shutdown()
    }

    @Test func originalTerminalLinksResolveInEngineAndRejectStaleOrRemoteFileTargets() async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.txt")
        try Data("synthetic terminal link".utf8).write(to: file)
        let local = MachineSession(machine: .local, local: true, synthetic: true)
        let remote = MachineSession(
            machine: Machine(name: "fixture", host: "fixture.invalid"), synthetic: true)
        var opened: [URL] = []
        let engine = MachineTerminalEngine(
            session: { $0 == local.id ? local : remote },
            openURL: {
                opened.append($0); return true
            }, launch: { _, _ in launch("exec cat") })
        var request = MachineTerminalRequest(operation: .open, machineID: local.id)
        request.handle = try await engine.execute(request).handle
        request.operation = .resolveLink; request.target = "./synthetic.txt"
        request.directory = root.path
        let first = try await engine.execute(request)
        let resolution = try JSONDecoder().decode(
            TerminalLinkResolution.self, from: #require(first.link))
        #expect(resolution.disposition == .allow)
        #expect(resolution.target == file.standardizedFileURL.absoluteString)
        request.operation = .openLink; request.linkID = first.linkID
        _ = try await engine.execute(request)
        #expect(opened.map(\.absoluteString) == [resolution.target])
        await #expect(throws: MachineUIError.self) { try await engine.execute(request) }
        request.operation = .resolveLink; request.target = "fixture-app:synthetic";
        request.untrusted = true
        let confirmation = try await engine.execute(request)
        #expect(
            try JSONDecoder().decode(TerminalLinkResolution.self, from: #require(confirmation.link))
                .disposition == .confirm)
        request.target = "https://fixture.invalid/\u{1b}"
        let denied = try await engine.execute(request)
        #expect(
            try JSONDecoder().decode(TerminalLinkResolution.self, from: #require(denied.link))
                .disposition == .deny)
        request.operation = .openLink; request.linkID = denied.linkID
        await #expect(throws: MachineUIError.self) { try await engine.execute(request) }
        var other = MachineTerminalRequest(operation: .open, machineID: remote.id)
        other.handle = try await engine.execute(other).handle
        other.operation = .resolveLink; other.target = "file:///private/tmp/synthetic.txt"
        let remoteFile = try await engine.execute(other)
        #expect(
            try JSONDecoder().decode(TerminalLinkResolution.self, from: #require(remoteFile.link))
                .disposition == .deny)
        #expect(opened.count == 1)
        await engine.shutdown()
    }

    @Test func originalTerminalMediaAndPromisedFilesStayOwnedAndByteExact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = MachinePaths.root; MachinePaths.root = root.appendingPathComponent("owner")
        defer { MachinePaths.root = old }
        let session = MachineSession(machine: .local, local: true, synthetic: true)
        let engine = MachineTerminalEngine(
            session: { _ in session }, launch: { _, _ in launch("exec cat") })
        var request = MachineTerminalRequest(
            operation: .open, machineID: session.id, presentationID: UUID())
        request.handle = try await engine.execute(request).handle
        let bytes = Data((0..<150_000).map { UInt8($0 % 251) })
        request.operation = .dropBegin; request.dropCount = UInt64(bytes.count);
        request.fileExtension = "png"
        request.dropID = try await engine.execute(request).dropID
        request.operation = .dropFinish
        await #expect(throws: MachineUIError.self) { try await engine.execute(request) }
        request.operation = .dropWrite
        request.offset = 1; request.bytes = bytes.prefix(16_384)
        await #expect(throws: MachineUIError.self) { try await engine.execute(request) }
        var wrong = request; wrong.tabID = UUID(); wrong.offset = 0
        await #expect(throws: MachineUIError.self) { try await engine.execute(wrong) }
        for offset in stride(from: 0, to: bytes.count, by: 16_384) {
            request.offset = UInt64(offset);
            request.bytes = bytes.subdata(in: offset..<min(offset + 16_384, bytes.count))
            let receipt = try await engine.execute(request)
            #expect(receipt.dropID == request.dropID)
            #expect(receipt.nextOffset == UInt64(offset + request.bytes.count))
        }
        request.operation = .dropFinish; request.bytes = Data()
        let media = try #require(try await engine.execute(request).paths.first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: media)) == bytes)
        let source = root.appendingPathComponent("promised")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try bytes.write(to: source.appendingPathComponent("binary.bin"))
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("link").path, withDestinationPath: "binary.bin")
        request.operation = .dropPaths; request.paths = [source.path];
        request.temporaryPaths = [source.path]
        let copied = URL(
            fileURLWithPath: try #require(try await engine.execute(request).paths.first))
        try FileManager.default.removeItem(at: source)
        #expect(try Data(contentsOf: copied.appendingPathComponent("binary.bin")) == bytes)
        #expect(FileManager.default.fileExists(atPath: copied.appendingPathComponent("empty").path))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: copied.appendingPathComponent("link").path) == "binary.bin")
        request.operation = .close
        _ = try await engine.execute(request)
        #expect(!FileManager.default.fileExists(atPath: media))
        #expect(!FileManager.default.fileExists(atPath: copied.path))
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
