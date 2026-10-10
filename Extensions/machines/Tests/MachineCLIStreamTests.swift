import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import MachinesExtension

extension MachineCLITests {
    @Suite @MainActor struct MachineCLIStreamTests {
        private func isolated(_ body: (Machine, URL) async throws -> Void) async throws {
            let previous = MachinePaths.root
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            MachinePaths.root = directory
            defer {
                MachinePaths.root = previous; try? FileManager.default.removeItem(at: directory)
            }
            let machine = Machine(name: "fixture-box", host: "fixture.invalid")
            MachineRegistry.add(machine)
            try await body(machine, directory)
        }

        nonisolated private func process(_ command: String) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            return process
        }

        private func start(
            _ service: MachineCLIService, arguments: [String], input: Data = Data(),
            session: UUID = UUID()
        ) throws -> ExtensionCLIStreamHandle {
            let request = ExtensionCLIStreamStart(
                owner: "machines", session: session,
                request: try ExtensionCLIRequest(arguments: arguments, standardInput: input),
                deadline: 10)
            return try JSONDecoder().decode(
                ExtensionCLIStreamHandle.self,
                from: service.invoke(
                    "machines.cli.stream.start", payload: JSONEncoder().encode(request)))
        }

        private func read(
            _ service: MachineCLIService, handle: ExtensionCLIStreamHandle, sequence: UInt64
        ) throws -> ExtensionCLIStreamFrame {
            try JSONDecoder().decode(
                ExtensionCLIStreamFrame.self,
                from: service.invoke(
                    "machines.cli.stream.read",
                    payload: JSONEncoder().encode(
                        ExtensionCLIStreamRead(handle: handle, sequence: sequence))))
        }

        @Test func originalExecDeliversBothStreamsBeforeCompletionAndPreservesExit() async throws {
            try await isolated { machine, _ in
                let child = process(
                    "printf 'early'; printf 'warning' >&2; sleep 0.15; printf ' final'; exit 23")
                let connection = SSHConnection(machine: machine, controlSocketMode: .isolated)
                await connection.acceptPlatform(.linux)
                let service = try MachineCLIService(runner: { machine, owner in
                    RemoteRunner(
                        machine: machine, connection: connection, owner: owner,
                        makeProcess: { _ in child }, connect: {})
                })
                let handle = try start(service, arguments: [machine.name, "printf fixture"])
                var sequence: UInt64 = 0
                var stdout = Data()
                var stderr = Data()
                var observedRunningOutput = false
                var exitCode: Int32?
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while exitCode == nil, ContinuousClock.now < deadline {
                    let frame = try read(service, handle: handle, sequence: sequence)
                    sequence = frame.nextSequence
                    for chunk in frame.chunks {
                        if chunk.channel == .stderr {
                            stderr += chunk.data
                        } else {
                            stdout += chunk.data
                        }
                    }
                    if frame.state == .running, !stdout.isEmpty { observedRunningOutput = true }
                    exitCode = frame.exitCode
                    try await Task.sleep(for: .milliseconds(10))
                }
                _ = try service.invoke(
                    "machines.cli.stream.end", payload: JSONEncoder().encode(handle))
                await service.shutdown()
                #expect(observedRunningOutput)
                #expect(stdout == Data("early final".utf8))
                #expect(stderr == Data("warning".utf8))
                #expect(exitCode == 23)
                #expect(!child.isRunning)
            }
        }

        @Test func cancellationAndDisableDrainExactlyOwnedRemoteRunner() async throws {
            try await isolated { machine, _ in
                let child = process("printf running; exec sleep 30")
                let service = try MachineCLIService(runner: { machine, owner in
                    RemoteRunner(
                        machine: machine, owner: owner, makeProcess: { _ in child }, connect: {})
                })
                let handle = try start(service, arguments: ["exec", machine.name, "--", "uptime"])
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !child.isRunning, ContinuousClock.now < deadline { await Task.yield() }
                #expect(child.isRunning)
                _ = try service.invoke(
                    "machines.cli.stream.cancel", payload: JSONEncoder().encode(handle))
                await service.shutdown()
                #expect(!child.isRunning)
                #expect(throws: ExtensionPeerError.self) {
                    try read(service, handle: handle, sequence: 0)
                }
            }
        }

        @Test func originalExecPreservesBinaryBytesAndSplitUTF8InStreamFrames() async throws {
            try await isolated { machine, _ in
                let child = process(
                    "printf '\\377\\000\\342'; sleep 0.03; printf '\\202\\254'; printf '\\376' >&2")
                let service = try MachineCLIService(runner: { machine, owner in
                    RemoteRunner(
                        machine: machine, owner: owner, makeProcess: { _ in child }, connect: {})
                })
                let handle = try start(service, arguments: ["exec", machine.name, "--", "fixture"])
                var sequence: UInt64 = 0
                var stdout = Data()
                var stderr = Data()
                var code: Int32?
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while code == nil, ContinuousClock.now < deadline {
                    let frame = try read(service, handle: handle, sequence: sequence)
                    sequence = frame.nextSequence
                    for chunk in frame.chunks {
                        if chunk.channel == .stderr {
                            stderr += chunk.data
                        } else {
                            stdout += chunk.data
                        }
                    }
                    code = frame.exitCode
                    try await Task.sleep(for: .milliseconds(10))
                }
                await service.shutdown()
                #expect(code == 0)
                #expect(stdout == Data([255, 0, 226, 130, 172]))
                #expect(stderr == Data([254]))
            }
        }

        @Test func callerInputAndWorkingDirectoryRemainOwnedContext() async throws {
            try await isolated { machine, directory in
                let connection = SSHConnection(machine: machine, controlSocketMode: .isolated)
                await connection.acceptPlatform(.linux)
                let service = try MachineCLIService(runner: { machine, owner in
                    RemoteRunner(
                        machine: machine, connection: connection, owner: owner,
                        makeProcess: { _ in process("cat; printf warning >&2; exit 9") },
                        connect: {})
                })
                let request = try ExtensionCLIRequest(
                    arguments: [machine.name, "cat"], standardInput: Data("caller input\n".utf8),
                    workingDirectory: directory.path)
                let reply = try await service.execute(request)
                #expect(reply.stdout == "caller input\n")
                #expect(reply.stderr == "warning")
                #expect(reply.exitCode == 9)
                let missing = try await service.execute(
                    ExtensionCLIRequest(
                        arguments: ["files", "put", machine.name, "missing.txt", "/fixture"],
                        workingDirectory: directory.path))
                #expect(missing.exitCode == 3)
                #expect(
                    missing.stderr.contains(directory.appendingPathComponent("missing.txt").path))
                let secret = try ExtensionCLIContext.$request.withValue(
                    ExtensionCLIRequest(
                        arguments: [], standardInput: Data("synthetic secret\n".utf8))
                ) {
                    try SecretInput.readFromStdin("password")
                }
                #expect(secret == "synthetic secret")
                await service.shutdown()
            }
        }

        @Test func originalMetricsCallbacksWriteToTheOwningStream() async throws {
            try await isolated { machine, _ in
                let sample = MachineSample(
                    ts: 1, dt: 2, cpu: MachineCPU(total: 31),
                    mem: MachineMemory(totalKB: 1000, availKB: 700, usedKB: 300), uptime: 120)
                var object = try #require(
                    JSONSerialization.jsonObject(with: JSONEncoder().encode(sample))
                        as? [String: Any])
                object["t"] = "sample"
                let line =
                    "@EDITH@"
                    + String(
                        decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                let child = process("printf '%s\\n' " + ShellQuote.quote(line))
                let connection = SSHConnection(machine: machine, controlSocketMode: .isolated)
                await connection.acceptPlatform(.linux)
                let service = try MachineCLIService(runner: { machine, owner in
                    RemoteRunner(
                        machine: machine, connection: connection, owner: owner,
                        makeProcess: { _ in child }, connect: {})
                })
                let handle = try start(
                    service, arguments: ["metrics", machine.name, "--follow", "--json"])
                var sequence: UInt64 = 0
                var bytes = Data()
                var code: Int32?
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while code == nil, ContinuousClock.now < deadline {
                    let frame = try read(service, handle: handle, sequence: sequence)
                    sequence = frame.nextSequence
                    for chunk in frame.chunks where chunk.channel == .stdout { bytes += chunk.data }
                    code = frame.exitCode
                    try await Task.sleep(for: .milliseconds(10))
                }
                await service.shutdown()
                #expect(code == 0)
                let reported = try #require(
                    JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                let reportedSample = try #require(reported["sample"] as? [String: Any])
                #expect((reportedSample["cpu"] as? [String: Any])?["totalPercent"] as? Double == 31)
            }
        }
    }
}
