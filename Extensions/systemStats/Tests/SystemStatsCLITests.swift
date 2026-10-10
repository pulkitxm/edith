import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import SystemStatsExtension

private struct FixtureStatsSampler: SystemStatsSampling {
    func hello() -> MachineHello {
        MachineHello(os: "fixtureOS", host: "sample-host", cores: 4, memTotalKB: 1000)
    }
    func sample() async -> MachineSample {
        MachineSample(
            ts: 100, dt: 2, cpu: MachineCPU(total: 25, cores: [25, 25, 25, 25]),
            mem: MachineMemory(totalKB: 1000, availKB: 500, usedKB: 500), load: [1, 2, 3],
            net: MachineNetwork(rxBps: 1000, txBps: 2000),
            procs: [
                MachineProcess(
                    pid: 42, user: "sample-user", cpu: 12, mem: 4, rssKB: 40,
                    name: "sample-process", cmd: "/sample/process")
            ])
    }
    func slow() async -> MachineSlow {
        MachineSlow(disks: [
            MachineFilesystem(
                fs: "sample-volume", mount: "/sample", totalKB: 1000,
                usedKB: 300, availKB: 700)
        ])
    }
}

@MainActor @Suite(.serialized) struct SystemStatsCLITests {
    @Test func originalFollowStreamsCallerContextAndStopsBeforeOwnerReturns() async throws {
        let previous = SystemStatsCLIEnvironment.makeSampler
        var observed: ExtensionCLIRequest?
        SystemStatsCLIEnvironment.makeSampler = {
            observed = ExtensionCLIContext.request
            return FixtureStatsSampler()
        }
        defer { SystemStatsCLIEnvironment.makeSampler = previous }
        let streams = try ExtensionCLIStreams(owner: "systemStats")
        defer { streams.stop() }
        let request = try ExtensionCLIRequest(
            arguments: ["stats", "--follow", "--interval", "0.5", "--json"],
            standardInput: Data("synthetic input".utf8),
            workingDirectory: "/tmp/synthetic-follow-context", interactive: true)
        let start = ExtensionCLIStreamStart(
            owner: "systemStats", session: UUID(), request: request, deadline: 5)
        let handle = try streams.start(SystemCommand.self, request: start)
        let deadline = ContinuousClock.now + .seconds(3)
        var sequence: UInt64 = 0
        var lines: [Data] = []
        while lines.count < 2 && ContinuousClock.now < deadline {
            let frame = try streams.read(ExtensionCLIStreamRead(handle: handle, sequence: sequence))
            sequence = frame.nextSequence
            #expect(frame.state == .running)
            for chunk in frame.chunks {
                #expect(chunk.channel == .stdout)
                lines.append(chunk.data)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(lines.count >= 2)
        #expect(observed == request)
        #expect(lines.allSatisfy { (try? JSONSerialization.jsonObject(with: $0)) != nil })
        await streams.stopAndWait()
        #expect(ExtensionCLIContext.request == nil)
        #expect(throws: (any Error).self) {
            try streams.read(ExtensionCLIStreamRead(handle: handle, sequence: sequence))
        }
        #expect(throws: (any Error).self) { try streams.start(SystemCommand.self, request: start) }
    }

    @Test func discoveryCatalogContainsOnlyOriginalParserRoutesAndRejectsForeignPayloads()
        throws
    {
        let data = try SystemStatsCLIExecution.catalog(Data("{}".utf8))
        let catalog = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["version"] as? Int == 1)
        #expect(catalog["owner"] as? String == "systemStats")
        #expect(catalog["acceptsInput"] as? Bool == false)
        let commands = try #require(catalog["commands"] as? [[String: Any]])
        let routes = commands.compactMap { $0["route"] as? [String] }
        let expected: [[String]] = [["system", "stats"], ["system", "disks"]]
        #expect(Set(routes) == Set(expected))
        #expect(routes.count == Set(routes).count)
        #expect(commands.allSatisfy { $0["operation"] as? String == "systemStats.cli" })
        let documents = try #require(catalog["parserHelp"] as? [[String: Any]])
        #expect(documents.count == 1)
        #expect(documents[0]["serializationVersion"] as? Int == 0)
        let help = try #require(documents[0]["command"] as? [String: Any])
        #expect(help["commandName"] as? String == "system")
        #expect(!routes.contains(["system"]))
        #expect(!routes.contains(["system", "status"]))
        let stats = try #require(
            commands.first { $0["route"] as? [String] == ["system", "stats"] })
        #expect(stats["streamOperation"] as? String == "systemStats.cli.stream")
        let disks = try #require(
            commands.first { $0["route"] as? [String] == ["system", "disks"] })
        #expect(disks["streamOperation"] == nil)
        #expect(throws: (any Error).self) {
            try SystemStatsCLIExecution.catalog(Data("{\"arguments\":[]}".utf8))
        }
    }

    @Test func originalActionReceivesTheExactCallerContextAndDoesNotLeakIt() async throws {
        let request = try ExtensionCLIRequest(
            arguments: ["disks", "--json"], standardInput: Data("synthetic terminal input".utf8),
            workingDirectory: "/tmp/synthetic-terminal-context", interactive: true)
        var observed: ExtensionCLIRequest?
        let reply = try await SystemStatsCLIExecution.run(request) {
            observed = ExtensionCLIContext.request
            return FixtureStatsSampler()
        }
        #expect(reply.exitCode == 0)
        #expect(observed == request)
        #expect(ExtensionCLIContext.request == nil)
    }
    @Test func originalStatsAndDisksOutputAndValidation() async throws {
        let stats = try await SystemStatsCLIExecution.run(
            ExtensionCLIRequest(arguments: ["stats", "--json", "--processes", "1"]),
            makeSampler: { FixtureStatsSampler() })
        let value = try #require(
            JSONSerialization.jsonObject(with: Data(stats.stdout.utf8)) as? [String: Any])
        let sample = try #require(value["sample"] as? [String: Any])
        let cpu = try #require(sample["cpu"] as? [String: Any])
        #expect(cpu["totalPercent"] as? Double == 25)
        #expect((sample["processes"] as? [[String: Any]])?.count == 1)
        #expect(stats.exitCode == 0 && stats.stderr.isEmpty)
        let disks = try await SystemStatsCLIExecution.run(
            ExtensionCLIRequest(arguments: ["disks"]), makeSampler: { FixtureStatsSampler() })
        #expect(disks.stdout.contains("sample-volume") && disks.stdout.contains("30%"))
        let invalid = try await SystemStatsCLIExecution.run(
            ExtensionCLIRequest(arguments: ["stats", "--interval", "0"]),
            makeSampler: { FixtureStatsSampler() })
        #expect(invalid.exitCode == 2)
    }

    @Test func followChunksPreserveHeaderOnceAndCompactJSON() async throws {
        let follow = SystemStatsFollow(makeSampler: { FixtureStatsSampler() })
        defer { follow.shutdown() }
        let request = SystemStatsFollowRequest(session: UUID(), json: false, processes: 1)
        let payload = try JSONEncoder().encode(request)
        let first = try JSONDecoder().decode(
            ExtensionCLIReply.self,
            from: await follow.execute("systemStats.follow.begin", payload: payload))
        let next = try JSONDecoder().decode(
            ExtensionCLIReply.self,
            from: await follow.execute("systemStats.follow.read", payload: payload))
        #expect(first.stdout.hasPrefix("sample-host  fixtureOS  4 cores\n"))
        #expect(!next.stdout.contains("sample-host"))
        #expect(next.stdout.contains("sample-process"))
        _ = try await follow.execute("systemStats.follow.end", payload: payload)
        await #expect(throws: (any Error).self) {
            try await follow.execute("systemStats.follow.read", payload: payload)
        }
        let json = SystemStatsFollowRequest(session: UUID(), json: true, processes: 0)
        let chunk = try JSONDecoder().decode(
            ExtensionCLIReply.self,
            from: await follow.execute(
                "systemStats.follow.begin", payload: JSONEncoder().encode(json)))
        #expect(chunk.stdout.split(separator: "\n").count == 1)
        #expect(try JSONSerialization.jsonObject(with: Data(chunk.stdout.utf8)) is [String: Any])
    }

    @Test func cancelledFollowBeginRetiresSessionAndStoppedOwnerRejectsReads() async throws {
        let follow = SystemStatsFollow(makeSampler: { FixtureStatsSampler() })
        let payload = try JSONEncoder().encode(SystemStatsFollowRequest(session: UUID()))
        let task = Task { try await follow.execute("systemStats.follow.begin", payload: payload) }
        await Task.yield()
        task.cancel()
        do {
            _ = try await task.value; Issue.record("cancelled follow returned output")
        } catch is CancellationError {} catch { Issue.record("unexpected error: \(error)") }
        follow.shutdown()
        await #expect(throws: (any Error).self) {
            try await follow.execute("systemStats.follow.begin", payload: payload)
        }
    }

    @Test func originalProcessParsingPreservesCommandsAndSortsCPU() {
        let processes = LocalMachineSampler.parseProcesses(
            "42 sample-user 12.5 3.0 100 /sample/one\n43 other 80 4 200 /sample/app with spaces\ninvalid\n"
        )
        #expect(processes.map(\.pid) == [43, 42])
        #expect(processes.first?.cmd == "/sample/app with spaces")
    }
}
