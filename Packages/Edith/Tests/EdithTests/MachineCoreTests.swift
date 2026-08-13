import Foundation
import Testing

@testable import EdithKit

@Suite struct ShellQuoteTests {
    @Test func passesSafeStringsThrough() {
        #expect(ShellQuote.quote("docker") == "docker")
        #expect(ShellQuote.quote("/var/run/docker.sock") == "/var/run/docker.sock")
        #expect(ShellQuote.quote("a-b_c.d:e@f%g,h+i=j") == "a-b_c.d:e@f%g,h+i=j")
    }

    @Test func quotesUnsafeStrings() {
        #expect(ShellQuote.quote("hello world") == "'hello world'")
        #expect(ShellQuote.quote("") == "''")
        #expect(ShellQuote.quote("a\"b") == "'a\"b'")
        #expect(ShellQuote.quote("$(rm -rf /)") == "'$(rm -rf /)'")
        #expect(ShellQuote.quote("{{json .}}") == "'{{json .}}'")
    }

    @Test func escapesSingleQuotes() {
        #expect(ShellQuote.quote("it's") == "'it'\\''s'")
    }

    @Test func joinsCommands() {
        #expect(
            ShellQuote.command(["docker", "ps", "-a", "--format", "{{json .}}"])
                == "docker ps -a --format '{{json .}}'")
    }
}

@Suite struct SSHConfigFileTests {
    private let sample = """
        Host *
          ServerAliveInterval 30
          StrictHostKeyChecking accept-new

        # personal laptop
        Host tuf
          HostName 192.168.1.12
          User pulkit
          IdentityFile ~/.ssh/id_ed25519

        Host bastion-*
          User ops

        Host db
          HostName "10.0.0.5"
          Port 2222
          IdentityFile "/Volumes/Ext Drive/keys/db.pem"

        Match host db
          User dbadmin

        Host db
          User firstwins
        """

    @Test func parsesQuotedValuesAndComments() {
        let lines = SSHConfigFile.parseLines("Key \"a value\" other # trailing\n#full comment")
        #expect(
            lines == [SSHConfigFile.ConfigLine(keyword: "Key", arguments: ["a value", "other"])])
    }

    @Test func parsesEqualsSeparator() {
        let lines = SSHConfigFile.parseLines("Port=2200")
        #expect(lines == [SSHConfigFile.ConfigLine(keyword: "Port", arguments: ["2200"])])
    }

    @Test func enumeratesOnlyConcreteAliases() {
        let hosts = SSHConfigFile.concreteHosts(
            configLines: SSHConfigFile.parseLines(sample))
        #expect(hosts.map(\.alias) == ["tuf", "db"])
    }

    @Test func resolvesFirstMatchValues() {
        let hosts = SSHConfigFile.concreteHosts(
            configLines: SSHConfigFile.parseLines(sample))
        let tuf = hosts.first { $0.alias == "tuf" }
        #expect(tuf?.hostName == "192.168.1.12")
        #expect(tuf?.user == "pulkit")
        #expect(tuf?.identityFile?.hasSuffix("/.ssh/id_ed25519") == true)
        #expect(tuf?.identityFile?.hasPrefix("~") == false)
    }

    @Test func handlesQuotedPathsAndPortsAndSkipsMatchBlocks() {
        let hosts = SSHConfigFile.concreteHosts(
            configLines: SSHConfigFile.parseLines(sample))
        let db = hosts.first { $0.alias == "db" }
        #expect(db?.hostName == "10.0.0.5")
        #expect(db?.port == 2222)
        #expect(db?.identityFile == "/Volumes/Ext Drive/keys/db.pem")
        #expect(db?.user == "firstwins")
    }

    @Test func displayTargetFormatsUserHostAndPort() {
        #expect(
            SSHConfigHost(alias: "a", hostName: "h", user: "u", port: 2222).displayTarget
                == "u@h:2222")
        #expect(SSHConfigHost(alias: "a", hostName: "h", port: 22).displayTarget == "h")
        #expect(SSHConfigHost(alias: "a").displayTarget == "a")
    }
}

@Suite struct MachineModelsTests {
    @Test func sshTargetUsesAliasWhenConfigSourced() {
        let machine = Machine(
            name: "Tuf", host: "192.168.1.12", username: "pulkit",
            source: .sshConfigAlias("tuf"))
        #expect(machine.sshTarget == "tuf")
    }

    @Test func sshTargetCombinesUserAndHost() {
        #expect(Machine(name: "A", host: "h", username: "u").sshTarget == "u@h")
        #expect(Machine(name: "A", host: "h").sshTarget == "h")
    }

    @Test func machineRoundTripsThroughCodable() throws {
        let machine = Machine(
            name: "Tuf", host: "192.168.1.12", port: 2222, username: "pulkit",
            auth: .keyFile(path: "/tmp/key", hasPassphrase: true),
            source: .sshConfigAlias("tuf"), wakeMACAddress: "aa:bb:cc:dd:ee:ff",
            createdAt: Date(timeIntervalSince1970: 1_754_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            Machine.self, from: encoder.encode(machine))
        #expect(decoded == machine)
    }

    @Test func askpassUsage() {
        #expect(MachineAuth.password.usesAskpass)
        #expect(MachineAuth.keyFile(path: "/k", hasPassphrase: true).usesAskpass)
        #expect(!MachineAuth.keyFile(path: "/k", hasPassphrase: false).usesAskpass)
        #expect(!MachineAuth.agent.usesAskpass)
    }

    @Test func forwardSpecTargetsLoopback() {
        let forward = PortForward(
            machineID: UUID(), localPort: 8080, remoteHost: "localhost", remotePort: 3000)
        #expect(forward.forwardSpec == "127.0.0.1:8080:localhost:3000")
    }
}

@Suite @MainActor struct MachineStoreTests {
    private func temporaryStore() -> (MachineStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachineStoreTests.\(UUID().uuidString)")
        let store = MachineStore(
            machinesFile: root.appendingPathComponent("machines.json"),
            forwardsFile: root.appendingPathComponent("forwards.json"),
            snippetsFile: root.appendingPathComponent("snippets.json"))
        return (store, root)
    }

    @Test func persistsMachinesAcrossInstances() {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine(
            name: "Tuf", host: "192.168.1.12", username: "pulkit",
            createdAt: Date(timeIntervalSince1970: 1_754_000_000))
        store.add(machine)

        let reloaded = MachineStore(
            machinesFile: root.appendingPathComponent("machines.json"),
            forwardsFile: root.appendingPathComponent("forwards.json"),
            snippetsFile: root.appendingPathComponent("snippets.json"))
        #expect(reloaded.machines == [machine])
    }

    @Test func updateReplacesAndRemoveDeletesRelatedRecords() {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var machine = Machine(name: "Tuf", host: "192.168.1.12")
        store.add(machine)
        machine.name = "Renamed"
        store.update(machine)
        #expect(store.machines.first?.name == "Renamed")

        store.addForward(PortForward(machineID: machine.id, localPort: 8080, remotePort: 80))
        store.addSnippet(CommandSnippet(machineID: machine.id, title: "T", command: "uptime"))
        store.remove(id: machine.id)
        #expect(store.machines.isEmpty)
        #expect(store.forwards.isEmpty)
        #expect(store.snippets.isEmpty)
    }

    @Test func snippetsIncludeGlobalOnes() {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let machineID = UUID()
        store.addSnippet(CommandSnippet(machineID: nil, title: "G", command: "uptime"))
        store.addSnippet(CommandSnippet(machineID: machineID, title: "M", command: "df"))
        store.addSnippet(CommandSnippet(machineID: UUID(), title: "O", command: "ls"))
        #expect(store.snippets(machineID: machineID).map(\.title) == ["G", "M"])
    }
}

@Suite struct MetricsDecoderTests {
    @Test func ignoresLinesWithoutSentinel() {
        #expect(MachineMetricsDecoder.decode(line: "motd banner text") == nil)
        #expect(MachineMetricsDecoder.decode(line: "{\"t\":\"hello\"}") == nil)
    }

    @Test func decodesHello() {
        let line =
            "@EDITH@{\"t\":\"hello\",\"v\":1,\"os\":\"Ubuntu 24.04\",\"osID\":\"ubuntu\","
            + "\"kernel\":\"6.8.0\",\"arch\":\"x86_64\",\"host\":\"tuf\",\"cpuModel\":\"AMD\","
            + "\"cores\":16,\"memTotalKB\":16000000,\"virtual\":false}"
        guard case let .hello(hello)? = MachineMetricsDecoder.decode(line: line) else {
            Issue.record("expected hello record")
            return
        }
        #expect(hello.os == "Ubuntu 24.04")
        #expect(hello.cores == 16)
        #expect(!hello.virtual)
    }

    @Test func decodesSample() {
        let line =
            "@EDITH@{\"t\":\"sample\",\"ts\":1754000000,\"dt\":2.00,"
            + "\"cpu\":{\"total\":12.5,\"steal\":0.0,\"cores\":[10.0,15.0]},"
            + "\"mem\":{\"totalKB\":16000000,\"availKB\":8000000,\"usedKB\":8000000,"
            + "\"buffcacheKB\":2000000,\"swapTotalKB\":1000000,\"swapUsedKB\":0},"
            + "\"load\":[0.52,0.40,0.31],\"tasks\":{\"runnable\":2,\"total\":345},"
            + "\"uptime\":86400,"
            + "\"disk\":{\"devices\":[{\"n\":\"nvme0n1\",\"readBps\":1024,\"writeBps\":2048,"
            + "\"busy\":3.5}],\"readBps\":1024,\"writeBps\":2048},"
            + "\"net\":{\"ifaces\":[{\"n\":\"wlan0\",\"rxBps\":5000,\"txBps\":900,"
            + "\"virtual\":false}],\"rxBps\":5000,\"txBps\":900},"
            + "\"procs\":[{\"pid\":1234,\"user\":\"pulkit\",\"cpu\":42.0,\"mem\":1.5,"
            + "\"rssKB\":245760,\"name\":\"node\",\"cmd\":\"node server.js\"}]}"
        guard case let .sample(sample)? = MachineMetricsDecoder.decode(line: line) else {
            Issue.record("expected sample record")
            return
        }
        #expect(sample.cpu.total == 12.5)
        #expect(sample.cpu.cores == [10.0, 15.0])
        #expect(sample.mem.usedPercent == 50.0)
        #expect(sample.load == [0.52, 0.40, 0.31])
        #expect(sample.disk.devices.first?.n == "nvme0n1")
        #expect(sample.net.rxBps == 5000)
        #expect(sample.procs.first?.name == "node")
    }

    @Test func decodesSlowWithOptionalSections() {
        let prefix =
            "@EDITH@{\"t\":\"slow\",\"disks\":[{\"fs\":\"/dev/nvme0n1p2\",\"mount\":\"/\","
            + "\"totalKB\":500000000,\"usedKB\":250000000,\"availKB\":225000000}],"
            + "\"temps\":[{\"label\":\"x86_pkg_temp\",\"c\":54.0}]"
        let base = prefix + ",\"fans\":[],\"platformProfile\":null}"
        guard case let .slow(slow)? = MachineMetricsDecoder.decode(line: base) else {
            Issue.record("expected slow record")
            return
        }
        #expect(slow.disks.first?.usedPercent == 50.0)
        #expect(slow.battery == nil)
        #expect(slow.gpu == nil)

        let full =
            prefix + ",\"fans\":[{\"label\":\"CPU fan\",\"rpm\":3600}],"
            + "\"platformProfile\":{\"current\":\"balanced\","
            + "\"choices\":[\"quiet\",\"balanced\",\"performance\"]},"
            + "\"battery\":{\"percent\":87,\"status\":\"Discharging\"},"
            + "\"gpu\":{\"name\":\"RTX 4060\",\"util\":11,\"memUsedMB\":800,"
            + "\"memTotalMB\":8188,\"temp\":45}}"
        guard case let .slow(rich)? = MachineMetricsDecoder.decode(line: String(full)) else {
            Issue.record("expected slow record")
            return
        }
        #expect(rich.battery?.percent == 87)
        #expect(rich.gpu?.name == "RTX 4060")
        #expect(rich.fans == [MachineFan(label: "CPU fan", rpm: 3600)])
        #expect(rich.platformProfile?.current == "balanced")
    }

    @Test func collectorDrivesItsOwnLoopSoOutputIsNotBuffered() {
        let text = String(decoding: MachineCollector.script() ?? Data(), as: UTF8.self)
        #expect(text.contains("exec awk"))
        #expect(text.contains("system(\"sleep "))
        #expect(text.contains("fflush()"))
        #expect(!text.contains("feeder |"))
        #expect(!text.contains("fflush(\"\")"))
    }

    @Test func collectorBatchesProcessCommandLinesIntoOneProcessSnapshot() {
        let text = String(decoding: MachineCollector.script() ?? Data(), as: UTF8.self)
        #expect(text.contains("ps -ww -eo pid=,args="))
        #expect(text.contains("pidCommand[pid]"))
        #expect(!text.contains("tr \\\"\\\\000\\\""))
    }

    @Test func collectorCachesPhysicalBlockDevicesInsteadOfSpawningPerDisk() {
        let text = String(decoding: MachineCollector.script() ?? Data(), as: UTF8.self)
        #expect(text.contains("readBlockDevices()"))
        #expect(text.contains("name in blockDevices"))
        #expect(!text.contains("system(\"[ -e /sys/block/"))
    }

    @Test func collectorScriptResourceExists() {
        let script = MachineCollector.script()
        #expect(script != nil)
        let text = String(decoding: script ?? Data(), as: UTF8.self)
        #expect(text.hasPrefix("#!/bin/sh"))
        #expect(text.contains("@EDITH@"))
    }

    @Test func collectorReadsFansAndPlatformProfilesFromSysfs() {
        let text = String(decoding: MachineCollector.script() ?? Data(), as: UTF8.self)
        #expect(text.contains("/fan\" j \"_input"))
        #expect(text.contains("/sys/firmware/acpi/platform_profile_choices"))
    }
}

@Suite struct MachineThermalControlsTests {
    @Test func parsesAProfileStatus() {
        let profile = MachineThermalControls.parseStatus(
            "balanced\nquiet balanced performance\n")
        #expect(profile?.current == "balanced")
        #expect(profile?.choices == ["quiet", "balanced", "performance"])
    }

    @Test func rejectsInvalidAndIncompleteProfiles() {
        #expect(MachineThermalControls.parseStatus("balanced\n") == nil)
        #expect(
            MachineThermalControls.setProfile(
                "performance; reboot", duration: .untilChanged, withSudoPassword: false) == nil)
    }

    @Test func permanentProfilesCancelAnyPreviousReversion() throws {
        let command = try #require(
            MachineThermalControls.setProfile(
                "balanced", duration: .untilChanged, withSudoPassword: false))
        #expect(command.contains("systemctl stop"))
        #expect(command.contains("rm -f"))
        #expect(!command.contains("--on-active="))
    }

    @Test func timedProfilesKeepTheOriginalAndScheduleOneReversion() throws {
        let command = try #require(
            MachineThermalControls.setProfile(
                "performance", duration: .thirtyMinutes, withSudoPassword: true))
        #expect(command.hasPrefix("sudo -S -p ''"))
        #expect(command.contains("--on-active=1800s"))
        #expect(command.contains(MachineThermalControls.revertUnit))
        #expect(command.contains("/run/edith-platform-profile-original"))
        #expect(!command.contains("performance;"))
    }
}

@Suite struct MachineResourcePolicyTests {
    @Test func processSamplingStartsImmediatelyAndThenUsesTheStride() {
        let decisions = (0..<12).filter {
            MachineResourcePolicy.shouldRefreshProcesses(sampleIndex: $0, stride: 5)
        }
        #expect(decisions == [0, 5, 10])
    }

    @Test func invalidProcessStrideStillMakesForwardProgress() {
        #expect(MachineResourcePolicy.shouldRefreshProcesses(sampleIndex: 0, stride: 0))
        #expect(MachineResourcePolicy.shouldRefreshProcesses(sampleIndex: 1, stride: -4))
    }

    @Test func dockerPollingIsResponsiveOnlyWhileObserved() {
        #expect(
            MachineResourcePolicy.dockerPollInterval(observerCount: 1)
                == MachineResourcePolicy.foregroundDockerPollInterval)
        #expect(
            MachineResourcePolicy.dockerPollInterval(observerCount: 0)
                == MachineResourcePolicy.backgroundDockerPollInterval)
        #expect(
            MachineResourcePolicy.backgroundDockerPollInterval
                > MachineResourcePolicy.foregroundDockerPollInterval)
    }

    @Test func latencyChecksAreSlowerThanMetricSamples() {
        #expect(MachineResourcePolicy.latencyProbeInterval >= 30)
        #expect(MachineResourcePolicy.localProcessSampleStride >= 5)
    }
}

private actor ProcessReadProbe {
    private var reads = 0

    func read() -> [MachineProcess] {
        reads += 1
        return [
            MachineProcess(
                pid: reads, user: "test", cpu: Double(reads), mem: 0, rssKB: 1,
                name: "sample-\(reads)", cmd: "sample-\(reads)")
        ]
    }

    func count() -> Int { reads }
}

@Suite struct LocalMachineSamplerResourceTests {
    @Test func reusesProcessSnapshotsBetweenRefreshes() async {
        let probe = ProcessReadProbe()
        let sampler = LocalMachineSampler(processSampleStride: 3) { await probe.read() }
        var processIDs: [Int] = []
        for _ in 0..<8 {
            processIDs.append(await sampler.sample().procs.first?.pid ?? 0)
        }
        #expect(processIDs == [1, 1, 1, 2, 2, 2, 3, 3])
        #expect(await probe.count() == 3)
    }
}

@Suite struct AskpassEntryTests {
    @Test func detectsConfirmationPrompts() {
        #expect(AskpassEntry.isConfirmationPrompt("Are you sure you want to continue?"))
        #expect(
            AskpassEntry.isConfirmationPrompt(
                "The authenticity of host 'x' can't be established. (yes/no/[fingerprint])"))
        #expect(!AskpassEntry.isConfirmationPrompt("pulkit@tuf's password:"))
    }

    @Test func skipsWhenNoAccountRequested() {
        #expect(!AskpassEntry.runIfRequested(arguments: ["edith"], environment: [:]))
    }
}

@Suite struct SSHConnectionArgumentTests {
    private let aliasMachine = Machine(
        name: "Tuf", host: "192.168.1.12", username: "pulkit", source: .sshConfigAlias("tuf"))

    @Test func masterBindsTheControlSocket() async {
        let connection = SSHConnection(machine: aliasMachine)
        let arguments = connection.masterArguments()
        let socketIndex = arguments.firstIndex(of: "-S")
        #expect(socketIndex != nil)
        #expect(arguments[(socketIndex ?? 0) + 1] == connection.controlSocketPath)
        #expect(arguments.contains("-M"))
        #expect(arguments.last == "tuf")
    }

    @Test func theMasterOutlivesTheProcessThatOpenedIt() async {
        let arguments = SSHConnection(machine: aliasMachine).masterArguments()
        #expect(arguments.contains("ControlPersist=\(SSHConnection.controlPersist)"))
    }

    @Test func execAndTerminalReuseTheSameSocket() async {
        let connection = SSHConnection(machine: aliasMachine)
        let socket = connection.controlSocketPath
        #expect(connection.execArguments(command: "uptime").contains(socket))
        #expect(connection.terminalArguments().contains(socket))
        #expect(connection.terminalArguments().contains("-tt"))
        #expect(connection.execArguments(command: "uptime").last == "uptime")
    }

    @Test func independentConnectionsDoNotShareControlSockets() async {
        let first = SSHConnection(machine: aliasMachine)
        let second = SSHConnection(machine: aliasMachine)
        #expect(first.controlSocketPath != second.controlSocketPath)
        #expect(URL(fileURLWithPath: first.controlSocketPath).lastPathComponent.count == 18)
    }

    @Test func sharedConnectionsUseTheMachineControlSocket() async {
        let connection = SSHConnection(machine: aliasMachine, controlSocketMode: .shared)
        #expect(connection.controlSocketPath == MachinePaths.socketFile(for: aliasMachine.id).path)
    }

    @Test func knownHostsPathsAreQuotedForSpaces() async {
        let connection = SSHConnection(machine: aliasMachine)
        let arguments = connection.masterArguments()
        guard let option = arguments.first(where: { $0.hasPrefix("UserKnownHostsFile=") }) else {
            Issue.record("expected a UserKnownHostsFile option")
            return
        }
        #expect(option.contains("\""))
        let quoted = option.dropFirst("UserKnownHostsFile=".count)
        #expect(quoted.filter { $0 == "\"" }.count == 4)
    }

    @Test func manualMachinesCarryPortAndIdentity() async {
        let machine = Machine(
            name: "Box", host: "10.0.0.5", port: 2222, username: "root",
            auth: .keyFile(path: "/tmp/key", hasPassphrase: false))
        let arguments = SSHConnection(machine: machine).masterArguments()
        #expect(arguments.contains("2222"))
        #expect(arguments.contains("/tmp/key"))
        #expect(arguments.contains("IdentitiesOnly=yes"))
        #expect(arguments.last == "root@10.0.0.5")
    }

    @Test func passwordMachinesDisablePublicKeyAuth() async {
        let machine = Machine(name: "Box", host: "10.0.0.5", username: "root", auth: .password)
        let arguments = SSHConnection(machine: machine).masterArguments()
        #expect(arguments.contains("PubkeyAuthentication=no"))
        #expect(arguments.contains("NumberOfPasswordPrompts=1"))
    }
}

@Suite struct SSHConnectionErrorTests {
    @Test func mapsCommonFailuresToFriendlyMessages() {
        #expect(
            SSHConnection.friendlyConnectError("pulkit@host: Permission denied (publickey).")
                .message.contains("Authentication failed"))
        #expect(
            SSHConnection.friendlyConnectError(
                "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@"
            ).message.contains("host key changed"))
        #expect(
            SSHConnection.friendlyConnectError("ssh: connect to host x port 22: Connection refused")
                .message.contains("refused"))
        #expect(
            SSHConnection.friendlyConnectError("ssh: Could not resolve hostname zzz")
                .message.contains("resolve"))
        #expect(SSHConnection.friendlyConnectError("").message == "Connection failed.")
    }

    @Test func onlyRetriesFailuresAnotherAttemptCouldFix() {
        #expect(
            SSHConnection.friendlyConnectError("ssh: connect to host x port 22: Connection refused")
                .isRecoverable)
        #expect(
            SSHConnection.friendlyConnectError(
                "ssh: connect to host x port 22: Operation timed out"
            )
            .isRecoverable)
        #expect(
            SSHConnection.friendlyConnectError("ssh: Could not resolve hostname zzz")
                .isRecoverable)
        #expect(
            SSHConnection.friendlyConnectError("something nobody has seen before")
                .isRecoverable)
        #expect(
            SSHConnection.friendlyConnectError("pulkit@host: Permission denied (publickey).")
                .isRecoverable == false)
        #expect(
            SSHConnection.friendlyConnectError("Host key verification failed.")
                .isRecoverable == false)
    }
}

@Suite struct SSHProcessWaitTests {
    private func process(_ command: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    @Test func returnsTheRealExitStatus() async throws {
        let process = try process("exit 23")
        let status = await SSHConnection.waitForExit(process, timeout: 5)
        #expect(status == 23)
    }

    @Test func returnsTheStatusWhenTheProcessAlreadyFinished() async throws {
        let process = try process("exit 0")
        process.waitUntilExit()
        let status = await SSHConnection.waitForExit(process, timeout: 30)
        #expect(status == 0)
        #expect(!process.isRunning)
    }

    @Test func terminatesAProcessAtItsDeadline() async throws {
        let process = try process("exec sleep 300")
        let status = await SSHConnection.waitForExit(process, timeout: 0.05)
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(status != 0)
    }

    @Test func manyShortCommandsKeepTheirExitStatuses() async throws {
        for _ in 0..<12 {
            let process = try process("exit 0")
            #expect(await SSHConnection.waitForExit(process, timeout: 30) == 0)
        }
    }
}

@Suite struct PipeReadingTests {
    @Test func deliversAvailableBytes() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("hello".utf8))
        try pipe.fileHandleForWriting.close()
        var received = Data()
        let consumed = PipeReading.consume(pipe.fileHandleForReading) { received.append($0) }
        #expect(consumed)
        #expect(String(decoding: received, as: UTF8.self) == "hello")
    }

    @Test func unregistersTheCallbackAtEndOfFile() throws {
        let pipe = Pipe()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { _ in }
        try pipe.fileHandleForWriting.close()
        let consumed = PipeReading.consume(handle) { _ in }
        #expect(!consumed)
        #expect(handle.readabilityHandler == nil)
    }

    @Test func repeatedEndOfFileReadsStayEmpty() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        var deliveries = 0
        for _ in 0..<20 {
            #expect(!PipeReading.consume(pipe.fileHandleForReading) { _ in deliveries += 1 })
        }
        #expect(deliveries == 0)
    }
}

@Suite struct MachineReconnectTests {
    @Test func replayRemovesOnlyForwardsThatFailed() {
        let machineID = UUID()
        let first = PortForward(machineID: machineID, localPort: 8001, remotePort: 3001)
        let second = PortForward(machineID: machineID, localPort: 8002, remotePort: 3002)
        let third = PortForward(machineID: machineID, localPort: 8003, remotePort: 3003)
        let remembered = Dictionary(
            uniqueKeysWithValues: [first, second, third].map { ($0.id, $0) })

        let retained = MachineForwardReplay.retainedForwards(
            remembered, failedIDs: [second.id])

        #expect(Set(retained.keys) == [first.id, third.id])
        #expect(retained[first.id] == first)
        #expect(retained[third.id] == third)
    }

    @Test func waitsLongerAfterEachFailureThenSettlesOnAFixedGap() {
        #expect(MachineReconnect.delay(afterFailures: 0) == 0)
        let delays = (1...8).map { MachineReconnect.delay(afterFailures: $0) }
        #expect(delays == delays.sorted())
        #expect(delays.first == 1)
        #expect(delays.last == MachineReconnect.longestDelay)
        #expect(delays.allSatisfy { $0 <= MachineReconnect.longestDelay })
    }

    @Test func staysQuietThroughABlipAndTurnsRedOnAnOutage() {
        for failures in 1...MachineReconnect.quietFailures {
            #expect(
                MachineReconnect.state(afterFailures: failures, reason: "nope") == .reconnecting)
        }
        #expect(
            MachineReconnect.state(
                afterFailures: MachineReconnect.quietFailures + 1, reason: "Connection refused.")
                == .failed(message: "Connection refused."))
    }

    @Test func aQuietReconnectIsBusyAndRetryableButNotConnected() {
        let state = MachineConnectionState.reconnecting
        #expect(state.isBusy)
        #expect(state.isRetryable)
        #expect(state.isConnected == false)
        #expect(MachineConnectionState.connecting.isRetryable == false)
        #expect(MachineConnectionState.disconnected.isRetryable == false)
    }
}
