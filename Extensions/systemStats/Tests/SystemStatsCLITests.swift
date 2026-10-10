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
