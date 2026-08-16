import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIMachineTests {
    static let alias = Machine(
        id: UUID(uuidString: "4303DCF1-52D8-4075-AE9B-C2FD86D3821A")!, name: "Asus TUF 7",
        host: "192.168.1.12", username: "pulkit", source: .sshConfigAlias("tuf"))
    static let manual = Machine(name: "Builder", host: "10.0.0.9", port: 2222, username: "root")
    static let all = [alias, manual]

    @Test func namesIncludeBothTheLabelAndTheSSHAlias() {
        #expect(MachineDirectory.names(from: Self.all) == ["Asus TUF 7", "tuf", "Builder"])
    }

    @Test func resolutionAcceptsNameAliasAndIdentifier() throws {
        let byName = try MachineDirectory.resolve("asus tuf 7", in: Self.all)
        let byAlias = try MachineDirectory.resolve("tuf", in: Self.all)
        let byID = try MachineDirectory.resolve(Self.alias.id.uuidString, in: Self.all)
        #expect(byName.id == Self.alias.id)
        #expect(byAlias.id == Self.alias.id)
        #expect(byID.id == Self.alias.id)
    }

    @Test func aUniquePrefixResolves() throws {
        let resolved = try MachineDirectory.resolve("buil", in: Self.all)
        #expect(resolved.id == Self.manual.id)
    }

    @Test func anAmbiguousPrefixFailsLoudly() {
        let machines = [
            Machine(name: "build-a", host: "a"), Machine(name: "build-b", host: "b"),
        ]
        #expect(throws: CLIFailure.self) {
            try MachineDirectory.resolve("build", in: machines)
        }
    }

    @Test func anUnknownNameIsNotFoundRatherThanAGenericFailure() {
        do {
            _ = try MachineDirectory.resolve("nope", in: Self.all)
            Issue.record("resolution should have failed")
        } catch let failure as CLIFailure {
            #expect(failure.kind == .notFound)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func anEmptyMachineListExplainsHowToAddOne() {
        do {
            _ = try MachineDirectory.resolve("tuf", in: [])
            Issue.record("resolution should have failed")
        } catch let failure as CLIFailure {
            #expect(failure.kind == .notFound)
            #expect(failure.hint?.contains("Machines") == true)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func summaryCarriesTheFieldsAnAgentNeeds() {
        guard case let .object(fields) = MachineDirectory.summary(Self.alias) else {
            Issue.record("summary should be an object")
            return
        }
        #expect(fields["name"] == .string("Asus TUF 7"))
        #expect(fields["sshAlias"] == .string("tuf"))
        #expect(fields["sshTarget"] == .string("tuf"))
        #expect(fields["source"] == .string("sshConfigAlias"))
        #expect(fields["port"] == .int(22))
    }

    @Test func manualMachinesReportNoAlias() {
        guard case let .object(fields) = MachineDirectory.summary(Self.manual) else {
            Issue.record("summary should be an object")
            return
        }
        #expect(fields["sshAlias"] == .null)
        #expect(fields["sshTarget"] == .string("root@10.0.0.9"))
        #expect(fields["port"] == .int(2222))
    }

    @Test func loadingAMissingFileYieldsNoMachinesRatherThanCrashing() {
        let missing = URL(fileURLWithPath: "/nonexistent/machines.json")
        #expect(MachineDirectory.load(from: missing).isEmpty)
    }

    @Test func samplesEncodeIntoStableFieldNames() {
        let sample = MachineSample(
            ts: 1_700_000_000, dt: 2, cpu: MachineCPU(total: 12.5, steal: 0, cores: [10, 15]),
            mem: MachineMemory(totalKB: 1000, availKB: 400, usedKB: 600),
            load: [1, 2, 3], tasks: MachineTasks(runnable: 1, total: 200), uptime: 60,
            net: MachineNetwork(rxBps: 100, txBps: 50))
        guard case let .object(fields) = MachineReports.sample(sample),
            case let .object(cpu)? = fields["cpu"],
            case let .object(memory)? = fields["memory"]
        else {
            Issue.record("sample should be a nested object")
            return
        }
        #expect(cpu["totalPercent"] == .double(12.5))
        #expect(memory["usedPercent"] == .double(60))
        #expect(fields["load"] == .doubles([1, 2, 3]))
    }

    @Test func dockerAvailabilityIsReportedAsAState() {
        #expect(
            MachineReports.availability(DockerAvailability(status: .missing))
                == .object(["state": .string("missing")]))
        guard
            case let .object(fields) = MachineReports.availability(
                DockerAvailability(status: .available(serverVersion: "27.0", hasCompose: true)))
        else {
            Issue.record("availability should be an object")
            return
        }
        #expect(fields["serverVersion"] == .string("27.0"))
        #expect(fields["compose"] == .bool(true))
    }
}

@Suite struct CLIMachineCrudTests {
    static func seed() {
        MachineRegistry.add(
            Machine(name: "Builder", host: "10.0.0.9", port: 2222, username: "root"))
    }

    @Test func addingAMachinePutsItOnTheListTheAppReads() async throws {
        try await CLIProbe.inWorld { world in
            let result = await CLIProbe.capture([
                "machines", "add", "shed", "--host", "10.0.0.4", "--user", "pi", "--json",
            ])
            #expect(result.code == 0)
            #expect(result.object?["name"] as? String == "shed")
            let stored = MachineRegistry.machines()
            #expect(stored.map(\.name) == ["shed"])
            #expect(stored.first?.username == "pi")
            #expect(world.postedNames().contains(IPC.Name.machinesChanged.rawValue))
        }
    }

    @Test func aDuplicateNameIsRefusedRatherThanMakingTheNameAmbiguous() async throws {
        try await CLIProbe.inWorld { _ in
            Self.seed()
            let result = await CLIProbe.capture([
                "machines", "add", "builder", "--host", "10.0.0.1",
            ])
            #expect(result.code == ExitCodes.failure)
            #expect(result.stdout.isEmpty)
            #expect(MachineRegistry.machines().count == 1)
        }
    }

    @Test func aPortOutsideTheLegalRangeIsRejectedBeforeAnythingIsWritten() async throws {
        try await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture([
                "machines", "add", "shed", "--host", "10.0.0.4", "--port", "70000",
            ])
            #expect(result.code == ExitCodes.failure)
            #expect(MachineRegistry.machines().isEmpty)
        }
    }

    @Test func aKeyFileThatIsNotThereIsNotFoundRatherThanStoredBlindly() async throws {
        try await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture([
                "machines", "add", "shed", "--host", "10.0.0.4", "--key", "/nowhere/id_ed25519",
            ])
            #expect(result.code == ExitCodes.notFound)
            #expect(MachineRegistry.machines().isEmpty)
        }
    }

    @Test func editingChangesOnlyWhatIsNamed() async throws {
        try await CLIProbe.inWorld { _ in
            Self.seed()
            let before = MachineRegistry.machines()[0]
            let result = await CLIProbe.capture([
                "machines", "edit", "builder", "--name", "shed", "--json",
            ])
            #expect(result.code == 0)
            let after = MachineRegistry.machines()[0]
            #expect(after.name == "shed")
            #expect(after.id == before.id)
            #expect(after.host == before.host)
            #expect(after.port == before.port)
            #expect(after.username == before.username)
        }
    }

    @Test func removingWithoutSayingYesTouchesNothing() async throws {
        try await CLIProbe.inWorld { world in
            Self.seed()
            let result = await CLIProbe.capture(["machines", "rm", "builder", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["removed"] as? Bool == false)
            #expect(MachineRegistry.machines().count == 1)
            #expect(!world.postedNames().contains(IPC.Name.machinesChanged.rawValue))
        }
    }

    @Test func removingTakesTheForwardsAndSnippetsWithIt() async throws {
        try await CLIProbe.inWorld { _ in
            Self.seed()
            let target = MachineRegistry.machines()[0]
            let other = Machine(name: "Other", host: "10.0.0.5")
            MachineRegistry.add(other)
            MachineRegistry.addForward(
                PortForward(machineID: target.id, localPort: 8080, remotePort: 80))
            MachineRegistry.addForward(
                PortForward(machineID: other.id, localPort: 9090, remotePort: 90))
            MachineRegistry.addSnippet(
                CommandSnippet(machineID: target.id, title: "logs", command: "log show --last 5m"))

            let result = await CLIProbe.capture(["machines", "rm", "builder", "--yes", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["forwards"] as? Int == 1)
            #expect(result.object?["snippets"] as? Int == 1)
            #expect(MachineRegistry.machines().map(\.name) == ["Other"])
            #expect(MachineRegistry.forwards().map(\.localPort) == [9090])
            #expect(MachineRegistry.snippets().isEmpty)
        }
    }

    @Test func forwardsAreNumberedByLocalPortAndCannotCollide() async throws {
        try await CLIProbe.inWorld { _ in
            Self.seed()
            for port in ["9090", "8080"] {
                let added = await CLIProbe.capture([
                    "machines", "forwards", "add", "builder", "--local", port,
                    "--remote", "80", "--json",
                ])
                #expect(added.code == 0)
            }
            let listed = await CLIProbe.capture([
                "machines", "forwards", "ls", "builder", "--json",
            ])
            let rows = listed.array as? [[String: Any]] ?? []
            #expect(rows.map { $0["localPort"] as? Int } == [8080, 9090])

            let clash = await CLIProbe.capture([
                "machines", "forwards", "add", "builder", "--local", "8080",
                "--remote", "81", "--json",
            ])
            #expect(clash.code == ExitCodes.failure)
            #expect(MachineRegistry.forwards().count == 2)

            let removed = await CLIProbe.capture([
                "machines", "forwards", "rm", "builder", "1", "--json",
            ])
            #expect(removed.code == 0)
            #expect(MachineRegistry.forwards().map(\.localPort) == [9090])
        }
    }

    @Test func aForwardNumberOutsideTheListIsNotFound() async throws {
        try await CLIProbe.inWorld { _ in
            Self.seed()
            let result = await CLIProbe.capture(["machines", "forwards", "rm", "builder", "4"])
            #expect(result.code == ExitCodes.notFound)
            #expect(result.stderr.contains("numbered from 1"))
        }
    }

    @Test func aSharedSnippetShowsUpOnEveryMachine() async throws {
        try await CLIProbe.inWorld { _ in
            Self.seed()
            MachineRegistry.add(Machine(name: "Other", host: "10.0.0.5"))
            _ = await CLIProbe.capture([
                "machines", "snippets", "add", "--shared", "builder", "disk", "df", "-h",
            ])
            _ = await CLIProbe.capture([
                "machines", "snippets", "add", "builder", "logs", "log", "show", "--last", "5m",
            ])
            let mine = await CLIProbe.capture(["machines", "snippets", "ls", "builder", "--json"])
            let theirs = await CLIProbe.capture(["machines", "snippets", "ls", "other", "--json"])
            #expect(
                (mine.array as? [[String: Any]] ?? []).map { $0["title"] as? String }
                    == ["disk", "logs"])
            #expect(
                (theirs.array as? [[String: Any]] ?? []).map { $0["title"] as? String }
                    == ["disk"])
            #expect(MachineRegistry.snippets().first?.command == "df -h")
            #expect(MachineRegistry.snippets().first?.machineID == nil)
        }
    }

    @Test func theStoreAndTheCLIReadTheSameList() async throws {
        try await CLIProbe.inWorld { _ in
            _ = await CLIProbe.capture([
                "machines", "add", "shed", "--host", "10.0.0.4", "--json",
            ])
            let store = await MachineStore()
            let listed = await CLIProbe.capture(["machines", "ls", "--json"])
            let rows = listed.array as? [[String: Any]] ?? []
            let names = await store.machines.map(\.name)
            #expect(rows.compactMap { $0["name"] as? String } == names)
        }
    }
}
