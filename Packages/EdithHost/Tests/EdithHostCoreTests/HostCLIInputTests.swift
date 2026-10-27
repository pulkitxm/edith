import Darwin
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostCLIInputTests {
    @Test func localVersionQueriesDoNotStartOptionalProviders() async throws {
        var descriptors: [Int32] = [-1, -1]
        #expect(pipe(&descriptors) == 0)
        defer { Darwin.close(descriptors[0]); Darwin.close(descriptors[1]) }
        let invoke: HostCLIProviderRegistry.Invoke = { _ in
            Issue.record("A local version query must not start optional providers.")
            throw HostCLIError.unavailable
        }
        for arguments in [
            ["version"], ["--version"], ["version", "--json"], ["--version", "--json"],
        ] {
            #expect(!(try await HostCommandCLI.liveInputForCommand(arguments, invoke: invoke)))
            #expect(
                try await HostCommandCLI.inputForCommand(
                    arguments, descriptor: descriptors[0], invoke: invoke
                ).isEmpty)
        }
    }

    @Test func helpRequestsNeverTakeLiveInput() async throws {
        let catalog = HostCLIProviderCatalog(
            owner: "database",
            commands: [
                HostCLIProviderCommand(
                    route: ["database", "query"], operation: "database.cli",
                    summary: "Run a query.", streamOperation: "database.cli.stream",
                    streamDeadline: 30, readsInput: true)
            ], acceptsInput: true)
        let data = try JSONEncoder().encode(catalog)
        let invoke: HostCLIProviderRegistry.Invoke = { request in
            if request.action == .ls {
                return Data(
                    "[{\"id\":\"database\",\"installed\":true,\"compatible\":true,\"enabled\":true,\"running\":true,\"disablePending\":false,\"removalPending\":false,\"version\":\"1\"}]"
                        .utf8)
            }
            if request.operation == "database.cli.catalog" { return data }
            throw HostCLIError.unavailable
        }
        #expect(
            try await HostCommandCLI.liveInputForCommand(["database", "query"], invoke: invoke))
        for help in ["--help", "-h"] {
            #expect(
                !(try await HostCommandCLI.liveInputForCommand(
                    ["database", "query", help], invoke: invoke)))
        }
    }

    @Test func nullDeviceInputEndsWithoutError() async throws {
        let null = open("/dev/null", O_RDONLY)
        #expect(null >= 0)
        defer { Darwin.close(null) }
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        defer { Darwin.close(fds[0]); Darwin.close(fds[1]) }
        let input = try HostCLIInput(descriptor: null, output: fds[1])
        #expect(try await input.receive() == nil)
    }

    @Test func originalColourAliasIsScopedToColorProvider() throws {
        let catalog = HostCLIProviderCatalog(
            owner: "colorPicker",
            commands: [
                HostCLIProviderCommand(
                    route: ["color", "get"], operation: "colorPicker.cli", summary: "Read colour."),
                HostCLIProviderCommand(
                    route: ["colour", "get"], operation: "colorPicker.cli", summary: "Read colour."),
            ], settings: [])
        try catalog.validate(owner: "colorPicker")
        #expect(HostCLIProviderCatalog.prefixes["colorPicker"] == ["color", "colour"])
    }

    @Test func originalMachineAliasAdmitsLiveInputOnlyFromDeclaredEnabledStream() async throws {
        let catalog = HostCLIProviderCatalog(
            owner: "machines",
            commands: [
                HostCLIProviderCommand(
                    route: ["machines"], operation: "machines.cli", summary: "Machine commands.")
            ], acceptsInput: true, machineAliases: ["synthetic-box"],
            aliasOperation: "machines.cli.alias",
            aliasStreamOperation: "machines.cli.alias.stream", aliasStreamDeadline: 30)
        try catalog.validate(owner: "machines")
        let data = try JSONEncoder().encode(catalog)
        let wire = LiveInputFixture()
        let invoke: HostCLIProviderRegistry.Invoke = { request in
            if request.action == .ls {
                return Data(
                    "[{\"id\":\"machines\",\"installed\":true,\"compatible\":true,\"enabled\":true,\"running\":true,\"disablePending\":false,\"removalPending\":false,\"version\":\"1\"}]"
                        .utf8)
            }
            if request.operation == "machines.cli.catalog" { return data }
            return try await wire.invoke(request)
        }
        #expect(
            try await HostCommandCLI.liveInputForCommand(["synthetic-box", "vim"], invoke: invoke))
        #expect(
            !(try await HostCommandCLI.liveInputForCommand(["machines", "ls"], invoke: invoke)))
        let registry = try await HostCLIProviderRegistry.load(invoke: invoke)
        let reply = try await registry.execute(["synthetic-box", "vim"], invoke: invoke)
        #expect(reply.exitCode == 7 && reply.stdout == "alias complete\n" && reply.stderr.isEmpty)
        #expect(await wire.context()?.arguments == ["synthetic-box", "vim"])

        let off: HostCLIProviderRegistry.Invoke = { _ in Data("[]".utf8) }
        #expect(!(try await HostCommandCLI.liveInputForCommand(["synthetic-box"], invoke: off)))
        let wrong = HostCLIProviderCatalog(
            owner: "calendar",
            commands: [
                HostCLIProviderCommand(
                    route: ["calendar"], operation: "calendar.cli", summary: "Calendar.")
            ], acceptsInput: true, machineAliases: ["synthetic-box"],
            aliasOperation: "calendar.cli.alias",
            aliasStreamOperation: "calendar.cli.stream", aliasStreamDeadline: 30)
        #expect(throws: HostCLIError.self) { try wrong.validate(owner: "calendar") }
        let reserved = HostCLIProviderCatalog(
            owner: "machines", commands: catalog.commands,
            machineAliases: ["agent"], aliasOperation: "machines.cli.alias")
        #expect(throws: HostCLIError.self) { try reserved.validate(owner: "machines") }

    }

    @Test func pipeBytesEOFCancellationAndFlagsStayOwned() async throws {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        let readFD = fds[0], writeFD = fds[1]
        defer { Darwin.close(readFD) }
        let flags = fcntl(readFD, F_GETFL)
        let input = try HostCLIInput(descriptor: readFD, output: writeFD)
        #expect(!input.interactive)
        let bytes = Data([0, 255, 13, 10, 4, 120])
        #expect(
            bytes.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) } == bytes.count
        )
        #expect(try await input.receive() == .bytes(bytes))
        Darwin.close(writeFD)
        #expect(try await input.receive() == nil)
        #expect(fcntl(readFD, F_GETFL) == flags)
        input.cancel()
        await #expect(throws: CancellationError.self) { try await input.receive() }
    }

    @Test func terminalResizeRawBytesAndCancellationRestoreTermios() async throws {
        var master: Int32 = -1, slave: Int32 = -1
        var initial = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        #expect(openpty(&master, &slave, nil, nil, &initial) == 0)
        let masterFD = master, slaveFD = slave
        defer { Darwin.close(masterFD); Darwin.close(slaveFD) }
        var before = termios()
        #expect(tcgetattr(slaveFD, &before) == 0)
        let input = try HostCLIInput(descriptor: slaveFD, output: slaveFD)
        #expect(input.interactive)
        var raw = termios()
        #expect(tcgetattr(slaveFD, &raw) == 0)
        #expect(raw.c_lflag & tcflag_t(ICANON | ECHO) == 0)
        #expect(try await input.receive() == .resize(columns: 80, rows: 24))
        let bytes = Data([0, 255, 3, 4, 13, 10])
        #expect(
            bytes.withUnsafeBytes { Darwin.write(masterFD, $0.baseAddress, $0.count) }
                == bytes.count)
        #expect(try await input.receive() == .bytes(bytes))
        var next = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        #expect(ioctl(slaveFD, TIOCSWINSZ, &next) == 0)
        #expect(try await input.receive() == .resize(columns: 120, rows: 40))
        let waiting = Task { try await input.receive() }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        var restored = termios()
        #expect(tcgetattr(slaveFD, &restored) == 0)
        #expect(restored.c_iflag == before.c_iflag && restored.c_oflag == before.c_oflag)
        #expect(
            restored.c_cflag == before.c_cflag && restored.c_lflag == before.c_lflag,
            "before=\(before.c_lflag) restored=\(restored.c_lflag)")
        #expect(
            withUnsafeBytes(of: restored.c_cc) { Data($0) }
                == withUnsafeBytes(of: before.c_cc) { Data($0) })
    }

    @Test func streamInputRetriesExactCursorAndRejectsStaleAcknowledgement() async throws {
        let fixture = LiveInputFixture()
        let stream = try await HostCLIStream.start(
            owner: "machines", operation: "machines.cli.stream",
            request: HostCLIInvocationContext(
                arguments: ["ssh"], standardInput: Data([1, 2]), interactive: true),
            invoke: { try await fixture.invoke($0) })
        try await stream.send(.bytes(Data([0, 255, 10])))
        try await stream.send(.resize(columns: 101, rows: 39))
        try await stream.send(nil)
        #expect(await fixture.sequences() == [0, 0, 1, 2])
        #expect(
            await fixture.events() == [
                .bytes(Data([0, 255, 10])), .resize(columns: 101, rows: 39),
            ])
        #expect(await fixture.eof())
        await #expect(throws: HostCLIError.self) { try await stream.send(.bytes(Data([1]))) }
        await stream.end()
        let stale = LiveInputFixture(stale: true)
        let rejected = try await HostCLIStream.start(
            owner: "machines", operation: "machines.cli.stream",
            request: HostCLIInvocationContext(arguments: []),
            invoke: { try await stale.invoke($0) })
        await #expect(throws: HostCLIError.self) { try await rejected.send(.bytes(Data([1]))) }
        await rejected.end(cancel: true)
    }
}

private actor LiveInputFixture {
    private var handle: HostCLIStreamHandle?
    private var invocation: HostCLIInvocationContext?
    private var cursor: [UInt64] = []
    private var received: [HostCLIInputEvent] = []
    private var ended = false
    private let stale: Bool
    init(stale: Bool = false) { self.stale = stale }
    func context() -> HostCLIInvocationContext? { invocation }
    func sequences() -> [UInt64] { cursor }
    func events() -> [HostCLIInputEvent] { received }
    func eof() -> Bool { ended }
    func invoke(_ request: HostCLIRequest) throws -> Data {
        let object = try JSONDecoder().decode(HostCLIJSON.self, from: request.payload).object ?? [:]
        if request.operation?.hasSuffix(".start") == true {
            let session = try #require(object["session"]?.string.flatMap(UUID.init(uuidString:)))
            invocation = try JSONDecoder().decode(
                HostCLIInvocationContext.self, from: (object["request"] ?? .null).encoded())
            let created = HostCLIStreamHandle(owner: "machines", session: session, token: UUID())
            handle = created
            return try JSONEncoder().encode(created)
        }
        if request.operation?.hasSuffix(".read") == true {
            let current = try #require(handle)
            let sequence = UInt64(try #require(object["sequence"]?.integer))
            let chunks: [HostCLIStreamFrame.Chunk] =
                ended
                ? [
                    .init(sequence: sequence, channel: .stdout, data: Data("alias complete\n".utf8))
                ] : []
            return try JSONEncoder().encode(
                HostCLIStreamFrame(
                    handle: current, sequence: sequence,
                    nextSequence: sequence + UInt64(chunks.count),
                    chunks: chunks, state: ended ? .completed : .running, exitCode: ended ? 7 : nil)
            )
        }
        if request.operation?.hasSuffix(".write") == true
            || request.operation?.hasSuffix(".resize") == true
        {
            let current = try #require(handle)
            let sequence = UInt64(try #require(object["sequence"]?.integer))
            cursor.append(sequence)
            let accepted = cursor.count > 1
            if accepted {
                if request.operation?.hasSuffix(".resize") == true {
                    received.append(
                        .resize(
                            columns: Int(try #require(object["columns"]?.integer)),
                            rows: Int(try #require(object["rows"]?.integer))))
                } else if object["end"] == .bool(true) {
                    ended = true
                } else {
                    received.append(
                        .bytes(
                            try #require(object["data"]?.string.flatMap { Data(base64Encoded: $0) })
                        ))
                }
            }
            return try JSONEncoder().encode(
                HostCLIStreamInputAck(
                    handle: current, sequence: sequence,
                    nextSequence: sequence + (accepted ? 1 : 0) + (stale ? 1 : 0),
                    accepted: accepted))
        }
        return Data("{}".utf8)
    }
}
