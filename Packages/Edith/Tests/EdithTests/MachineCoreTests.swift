import Foundation
import Testing

@testable import EdithCore
@testable import EdithKit

private func decodedMachinePowerShell(_ command: String) -> String? {
    guard let encoded = command.split(separator: " ").last,
        let data = Data(base64Encoded: String(encoded))
    else { return nil }
    return String(data: data, encoding: .utf16LittleEndian)
}

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

@Suite struct SSHConnectionPlatformTests {
    @Test func supportsMacOSLinuxAndWindows() {
        #expect(SSHConnection.supportsPlatform("Darwin"))
        #expect(SSHConnection.supportsPlatform("Linux"))
        #expect(SSHConnection.supportsPlatform("Windows_NT"))
    }

    @Test func rejectsUnknownRemotePlatforms() {
        #expect(!SSHConnection.supportsPlatform("FreeBSD"))
        #expect(!SSHConnection.supportsPlatform(""))
    }
}

@Suite struct PowerShellTests {
    @Test func quotesLiteralValues() {
        #expect(PowerShell.literal("C:\\Users\\O'Brien") == "'C:\\Users\\O''Brien'")
    }

    @Test func encodesCommandsAsUTF16LE() throws {
        let command = PowerShell.command("Write-Output 'hello'")
        let encoded = try #require(command.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        #expect(String(data: data, encoding: .utf16LittleEndian) == "Write-Output 'hello'")
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
            source: .sshConfigAlias("tuf"), sshClipboardEnabled: true,
            wakeMACAddress: "aa:bb:cc:dd:ee:ff",
            createdAt: Date(timeIntervalSince1970: 1_754_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            Machine.self, from: encoder.encode(machine))
        #expect(decoded == machine)
    }

    @Test func machinesWithoutClipboardPreferenceDecodeAsDisabled() throws {
        let machine = Machine(name: "Tuf", host: "192.168.1.12")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(machine)) as? [String: Any])
        object.removeValue(forKey: "sshClipboardEnabled")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            Machine.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!decoded.sshClipboardEnabled)
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

@Suite struct SSHClipboardConfigurationTests {
    private let first = Machine(
        id: UUID(uuidString: "01010101-0101-0101-0101-010101010101")!, name: "Tuf",
        host: "10.77.0.2", username: "pulkit", source: .sshConfigAlias("tuf-wired"),
        sshClipboardEnabled: true)

    @Test func configUsesTheUpstreamSnakeCaseSchema() throws {
        let config = SSHClipboardConfiguration(
            nodeID: UUID(uuidString: "02020202-0202-0202-0202-020202020202")!,
            nodeName: "mac",
            peers: [SSHClipboardPeerConfiguration(name: "Tuf", sshCommand: "ssh tuf")])
        let object = try #require(
            JSONSerialization.jsonObject(with: config.encoded()) as? [String: Any])
        #expect(object["node_id"] as? String == "02020202-0202-0202-0202-020202020202")
        #expect(object["node_name"] as? String == "mac")
        #expect(object["poll_interval_ms"] as? Int == 75)
        #expect(try SSHClipboardConfiguration.decode(config.encoded()) == config)
    }

    @Test func sshCommandsPreserveAliasesAndManualPorts() {
        #expect(
            SSHClipboardConfiguration.sshCommand(for: first) == "/usr/bin/ssh tuf-wired")
        let manual = Machine(
            name: "Build", host: "10.0.0.5", port: 2222, username: "root",
            sshClipboardEnabled: true)
        #expect(
            SSHClipboardConfiguration.sshCommand(for: manual)
                == "/usr/bin/ssh -p 2222 root@10.0.0.5")
    }

    @Test func enablingIsIdempotentAndReplacesChangedConnections() {
        var config = SSHClipboardConfiguration(nodeName: "mac")
        config.enable(first)
        config.enable(first)
        #expect(config.peers.count == 1)
        var moved = first
        moved.source = .sshConfigAlias("tuf-wifi")
        config.enable(moved, replacing: first)
        #expect(
            config.peers == [
                SSHClipboardPeerConfiguration(name: "Tuf", sshCommand: "/usr/bin/ssh tuf-wifi")
            ])
    }

    @Test func disablingPreservesUnrelatedPeers() {
        var config = SSHClipboardConfiguration(
            nodeName: "mac",
            peers: [SSHClipboardPeerConfiguration(name: "Other", sshCommand: "ssh other")])
        config.enable(first)
        config.disable(first)
        #expect(
            config.peers == [
                SSHClipboardPeerConfiguration(name: "Other", sshCommand: "ssh other")
            ])
    }

    @Test func remoteInstallPlacesTheNativeBinaryOnTheManagedPath() {
        let command = SSHClipboardManager.remoteInstallCommand(version: "0.2.8")
        #expect(command.contains("vendor/$os-$arch/ssh-clipboard"))
        #expect(command.contains("$HOME/.local/bin/ssh-clipboard"))
        #expect(command.contains("chmod 755"))
        #expect(command.contains("mv \"$temporary\""))
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
            "@EDITH@{\"t\":\"hello\",\"v\":1,\"os\":\"macOS 26.0\",\"osID\":\"macos\","
            + "\"kernel\":\"25.0.0\",\"arch\":\"arm64\",\"host\":\"studio\","
            + "\"cpuModel\":\"Apple M4 Max\",\"cores\":16,\"memTotalKB\":16000000,"
            + "\"virtual\":false}"
        guard case let .hello(hello)? = MachineMetricsDecoder.decode(line: line) else {
            Issue.record("expected hello record")
            return
        }
        #expect(hello.os == "macOS 26.0")
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
            + "\"disk\":{\"devices\":[{\"n\":\"disk3\",\"readBps\":1024,\"writeBps\":2048,"
            + "\"busy\":3.5}],\"readBps\":1024,\"writeBps\":2048},"
            + "\"net\":{\"ifaces\":[{\"n\":\"en0\",\"rxBps\":5000,\"txBps\":900,"
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
        #expect(sample.disk.devices.first?.n == "disk3")
        #expect(sample.net.rxBps == 5000)
        #expect(sample.procs.first?.name == "node")
    }

    @Test func decodesSlowWithOptionalSections() {
        let prefix =
            "@EDITH@{\"t\":\"slow\",\"disks\":[{\"fs\":\"/dev/disk3s1s1\",\"mount\":\"/\","
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

    @Test func collectorUsesMacMetricsCommands() {
        let text = String(decoding: MachineCollector.script() ?? Data(), as: UTF8.self)
        #expect(text.contains("sw_vers"))
        #expect(text.contains("sysctl"))
        #expect(text.contains("vm_stat"))
        #expect(text.contains("top -l 1"))
    }

    @Test func collectorUsesLinuxMetricsSources() {
        let text = String(decoding: MachineCollector.script() ?? Data(), as: UTF8.self)
        #expect(text.contains("/etc/os-release"))
        #expect(text.contains("/proc/stat"))
        #expect(text.contains("/proc/meminfo"))
        #expect(text.contains("/proc/diskstats"))
        #expect(text.contains("/proc/net/dev"))
    }

    @Test func collectorDrivesItsLinuxLoopWithoutBufferedPipes() {
        let text = String(decoding: MachineCollector.script() ?? Data(), as: UTF8.self)
        #expect(text.contains("exec awk"))
        #expect(text.contains("system(\"sleep "))
        #expect(text.contains("fflush()"))
        #expect(!text.contains("feeder |"))
        #expect(!text.contains("fflush(\"\")"))
    }

    @Test func collectorBatchesLinuxProcessCommandLines() {
        let text = String(decoding: MachineCollector.script() ?? Data(), as: UTF8.self)
        #expect(text.contains("ps -ww -eo pid=,args="))
        #expect(text.contains("pidCommand[pid]"))
        #expect(!text.contains("tr \"\\000\""))
    }

    @Test func collectorCachesPhysicalLinuxBlockDevices() {
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

    @Test func windowsCollectorUsesCIMMetrics() {
        let script = MachineCollector.script(for: .windows, follow: false, interval: 5)
        let text = String(decoding: script ?? Data(), as: UTF8.self)
        #expect(text.hasPrefix("$EdithMode = 'once'\n$EdithInterval = 5"))
        #expect(text.contains("Win32_OperatingSystem"))
        #expect(text.contains("Win32_PerfFormattedData_PerfOS_Processor"))
        #expect(text.contains("Win32_PerfFormattedData_Tcpip_NetworkInterface"))
        #expect(text.contains("@EDITH@"))
    }

    @Test func collectorSelectsShellForEachPlatform() {
        #expect(MachineCollector.command(for: .linux, follow: true) == "sh -s -- --stream -i 2")
        #expect(MachineCollector.command(for: .darwin, follow: false) == "sh -s -- --once")
        let windows = MachineCollector.command(for: .windows, follow: true)
        #expect(windows.contains("powershell.exe"))
        #expect(decodedMachinePowerShell(windows)?.contains("[Console]::In.ReadToEnd()") == true)
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
        #expect(command.hasPrefix("/usr/bin/sudo -S -p ''"))
        #expect(command.contains("exec </dev/null"))
        #expect(command.contains("--on-active=1800s"))
        #expect(command.contains(MachineThermalControls.revertUnit))
        #expect(command.contains("/run/edith-platform-profile-original"))
        #expect(!command.contains("performance;"))
    }

    @Test func parsesWindowsPowerSchemesWithSpaces() {
        let profile = WindowsPowerProfileCommands.parseStatus(
            "Balanced\nPower saver\nBalanced\nHigh performance\n")

        #expect(profile?.current == "Balanced")
        #expect(profile?.choices == ["Power saver", "Balanced", "High performance"])
        #expect(WindowsPowerProfileCommands.parseStatus("Balanced\nPower saver\n") == nil)
    }

    @Test func buildsWindowsPowerSchemeCommandsAndReversion() throws {
        let status = try #require(decodedMachinePowerShell(WindowsPowerProfileCommands.status))
        let permanent = try #require(
            WindowsPowerProfileCommands.setProfile("Power saver", durationSeconds: 0))
        let timed = try #require(
            WindowsPowerProfileCommands.setProfile("High performance", durationSeconds: 1_800))
        let permanentScript = try #require(decodedMachinePowerShell(permanent))
        let timedScript = try #require(decodedMachinePowerShell(timed))

        #expect(status.contains("powercfg.exe /getactivescheme"))
        #expect(status.contains("powercfg.exe /list"))
        #expect(permanentScript.contains("$requested = 'Power saver'"))
        #expect(permanentScript.contains("powercfg.exe /setactive $selectedGuid"))
        #expect(!permanentScript.contains("Start-Sleep"))
        #expect(timedScript.contains("Start-Sleep -Seconds 1800"))
        #expect(timedScript.contains("power-profile-revert.json"))
        #expect(WindowsPowerProfileCommands.setProfile("\n", durationSeconds: 0) == nil)
    }
}

@Suite struct MachineControlCenterCommandsTests {
    @Test func mapsRemotePlatformsToControlPlatforms() {
        #expect(MachineControlPlatform(.darwin) == .darwin)
        #expect(MachineControlPlatform(.linux) == .linux)
        #expect(MachineControlPlatform(.windows) == .windows)
    }

    @Test func parsesACompleteSnapshot() {
        let snapshot = MachineControlCenterCommands.parseStatus(
            """
            EDITH_CONTROL_PLATFORM=linux
            EDITH_CONTROL_BATTERY_LEVEL=73
            EDITH_CONTROL_BATTERY_PLUGGED_IN=1
            EDITH_CONTROL_BRIGHTNESS=61
            EDITH_CONTROL_VOLUME=42
            EDITH_CONTROL_KEYBOARD_BACKLIGHT=18
            EDITH_CONTROL_MUTED=1
            EDITH_CONTROL_WIFI_ENABLED=0
            EDITH_CONTROL_BLUETOOTH_ENABLED=1
            EDITH_CONTROL_AIRPLANE_MODE=0
            EDITH_CONTROL_DO_NOT_DISTURB=1
            """)

        #expect(
            snapshot
                == MachineControlSnapshot(
                    platform: .linux,
                    batteryLevel: 73,
                    batteryPluggedIn: true,
                    brightness: 61,
                    volume: 42,
                    keyboardBacklight: 18,
                    muted: true,
                    wifiEnabled: false,
                    bluetoothEnabled: true,
                    airplaneMode: false,
                    doNotDisturb: true
                ))
        #expect(!snapshot.isEmpty)
    }

    @Test func parsesSparseSnapshots() {
        let snapshot = MachineControlCenterCommands.parseStatus(
            "banner text\nEDITH_CONTROL_WIFI_ENABLED=1\nunknown=value\n")

        #expect(snapshot.wifiEnabled == true)
        #expect(snapshot.batteryLevel == nil)
        #expect(snapshot.brightness == nil)
        #expect(snapshot.volume == nil)
        #expect(!snapshot.isEmpty)
        #expect(MachineControlCenterCommands.parseStatus("banner text").isEmpty)
    }

    @Test func parsesWindowsSnapshots() {
        let snapshot = MachineControlCenterCommands.parseStatus(
            """
            EDITH_CONTROL_PLATFORM=windows
            EDITH_CONTROL_BATTERY_LEVEL=81
            EDITH_CONTROL_BRIGHTNESS=55
            EDITH_CONTROL_VOLUME=34
            EDITH_CONTROL_MUTED=0
            EDITH_CONTROL_WIFI_ENABLED=1
            EDITH_CONTROL_BLUETOOTH_ENABLED=0
            EDITH_CONTROL_AIRPLANE_MODE=0
            EDITH_CONTROL_DO_NOT_DISTURB=1
            """)

        #expect(snapshot.platform == .windows)
        #expect(snapshot.batteryLevel == 81)
        #expect(snapshot.brightness == 55)
        #expect(snapshot.volume == 34)
        #expect(snapshot.muted == false)
        #expect(snapshot.wifiEnabled == true)
        #expect(snapshot.bluetoothEnabled == false)
        #expect(snapshot.airplaneMode == false)
        #expect(snapshot.doNotDisturb == true)
    }

    @Test func buildsNativeWindowsStatusAndMutations() throws {
        let status = try #require(decodedMachinePowerShell(WindowsMachineControlCommands.status))
        let brightness = try #require(
            decodedMachinePowerShell(
                MachineControlCenterCommands.command(
                    for: .setBrightness(140), withSudoPassword: false,
                    platform: .windows)))
        let volume = try #require(
            decodedMachinePowerShell(
                MachineControlCenterCommands.command(
                    for: .setVolume(-10), withSudoPassword: false,
                    platform: .windows)))
        let airplane = try #require(
            decodedMachinePowerShell(
                MachineControlCenterCommands.command(
                    for: .setAirplaneMode(true), withSudoPassword: false,
                    platform: .windows)))

        #expect(status.contains("EDITH_CONTROL_PLATFORM=windows"))
        #expect(status.contains("WmiMonitorBrightness"))
        #expect(status.contains("Get-NetAdapter"))
        #expect(status.contains("Get-PnpDevice -Class Bluetooth"))
        #expect(status.contains("IAudioEndpointVolume"))
        #expect(brightness.contains("Brightness = [byte]100"))
        #expect(volume.contains("[EdithAudio]::Level = 0"))
        #expect(airplane.contains(MachineControlCenterCommands.disruptiveMarker))
        #expect(airplane.contains("Disable-NetAdapter"))
        #expect(airplane.contains("Disable-PnpDevice"))
    }

    @Test func parsesBatteryOnlySnapshots() {
        let snapshot = MachineControlCenterCommands.parseStatus(
            "EDITH_CONTROL_BATTERY_LEVEL=70\nEDITH_CONTROL_BATTERY_PLUGGED_IN=0\n")

        #expect(snapshot.batteryLevel == 70)
        #expect(snapshot.batteryPluggedIn == false)
        #expect(!snapshot.hasControlSettings)
        #expect(!snapshot.isEmpty)
    }

    @Test func preservesZeroLevelsAndFalseFlags() {
        let snapshot = MachineControlCenterCommands.parseStatus(
            """
            EDITH_CONTROL_BRIGHTNESS=0
            EDITH_CONTROL_VOLUME=0
            EDITH_CONTROL_KEYBOARD_BACKLIGHT=0
            EDITH_CONTROL_MUTED=0
            EDITH_CONTROL_WIFI_ENABLED=0
            """)

        #expect(snapshot.brightness == 0)
        #expect(snapshot.volume == 0)
        #expect(snapshot.keyboardBacklight == 0)
        #expect(snapshot.muted == false)
        #expect(snapshot.wifiEnabled == false)
    }

    @Test func ignoresMalformedValues() {
        let snapshot = MachineControlCenterCommands.parseStatus(
            """
            EDITH_CONTROL_BRIGHTNESS=-1
            EDITH_CONTROL_BATTERY_LEVEL=101
            EDITH_CONTROL_BATTERY_PLUGGED_IN=charging
            EDITH_CONTROL_VOLUME=101
            EDITH_CONTROL_KEYBOARD_BACKLIGHT=half
            EDITH_CONTROL_MUTED=true
            EDITH_CONTROL_WIFI_ENABLED=2
            EDITH_CONTROL_BLUETOOTH_ENABLED=
            EDITH_CONTROL_AIRPLANE_MODE=no
            EDITH_CONTROL_DO_NOT_DISTURB=-1
            """)

        #expect(snapshot.isEmpty)
    }

    @Test func malformedDuplicatesDoNotEraseValidValues() {
        let snapshot = MachineControlCenterCommands.parseStatus(
            """
            EDITH_CONTROL_BRIGHTNESS=34
            EDITH_CONTROL_BRIGHTNESS=too-bright
            EDITH_CONTROL_WIFI_ENABLED=0
            EDITH_CONTROL_WIFI_ENABLED=unknown
            """)

        #expect(snapshot.brightness == 34)
        #expect(snapshot.wifiEnabled == false)
    }

    @Test func clampsNumericActions() {
        let lowBrightness = MachineControlCenterCommands.command(
            for: .setBrightness(-20), withSudoPassword: false)
        let highVolume = MachineControlCenterCommands.command(
            for: .setVolume(140), withSudoPassword: false)
        let highKeyboard = MachineControlCenterCommands.command(
            for: .setKeyboardBacklight(Int.max), withSudoPassword: false)

        #expect(lowBrightness.contains("level=0"))
        #expect(lowBrightness.contains("brightness 0.0"))
        #expect(highVolume.contains("level=100"))
        #expect(highVolume.contains("output volume 100"))
        #expect(highKeyboard.contains("level=100"))
        #expect(highKeyboard.contains("mac-brightnessctl 1.0"))
    }

    @Test func buildsPrivilegeModesWithoutDynamicExecutables() {
        let passwordCommand = MachineControlCenterCommands.command(
            for: .setAirplaneMode(true), withSudoPassword: true)
        let nonInteractiveCommand = MachineControlCenterCommands.command(
            for: .setWiFiEnabled(false), withSudoPassword: false)
        let passwordWiFiCommand = MachineControlCenterCommands.command(
            for: .setWiFiEnabled(false), withSudoPassword: true)

        #expect(
            passwordCommand.contains("/usr/bin/sudo -S -p '' sh -c 'exec </dev/null;"))
        #expect(passwordCommand.contains("exec rfkill \"$1\" all"))
        #expect(
            nonInteractiveCommand.contains("/usr/bin/sudo -n sh -c 'exec </dev/null;"))
        #expect(nonInteractiveCommand.contains("exec rfkill \"$1\" wlan"))
        #expect(
            passwordWiFiCommand.contains(
                "/usr/bin/sudo -S -p '' sh -c 'exec </dev/null;"))
        #expect(passwordWiFiCommand.contains("exec networksetup -setairportpower"))
        #expect(!passwordCommand.contains("eval"))
        #expect(!nonInteractiveCommand.contains("eval"))
        #expect(passwordCommand.contains(">/dev/null"))
        #expect(!passwordCommand.contains("rfkill block all >/dev/null 2>&1"))
        #expect(!nonInteractiveCommand.contains("rfkill block wlan >/dev/null 2>&1"))
    }

    @Test func attachesSudoPasswordsOnlyToActionsThatCanUseThem() {
        #expect(
            !MachineControlCenterCommands.shouldAttachSudoPassword(
                for: .setVolume(50), platform: .linux))
        #expect(
            !MachineControlCenterCommands.shouldAttachSudoPassword(
                for: .setMuted(true), platform: nil))
        #expect(
            !MachineControlCenterCommands.shouldAttachSudoPassword(
                for: .setDoNotDisturb(true), platform: .linux))
        #expect(
            !MachineControlCenterCommands.shouldAttachSudoPassword(
                for: .setBrightness(50), platform: .darwin))
        #expect(
            !MachineControlCenterCommands.shouldAttachSudoPassword(
                for: .setBluetoothEnabled(true), platform: .darwin))
        #expect(
            MachineControlCenterCommands.shouldAttachSudoPassword(
                for: .setBrightness(50), platform: .linux))
        #expect(
            MachineControlCenterCommands.shouldAttachSudoPassword(
                for: .setWiFiEnabled(false), platform: .darwin))
        #expect(
            !MachineControlCenterCommands.shouldAttachSudoPassword(
                for: .setAirplaneMode(true), platform: nil))
        #expect(
            !MachineControlCenterCommands.shouldAttachSudoPassword(
                for: .setWiFiEnabled(false), platform: .windows))
    }

    @Test func protectsSudoInputFromUnprivilegedFallbacks() {
        let brightness = MachineControlCenterCommands.command(
            for: .setBrightness(50), withSudoPassword: true)
        let wifi = MachineControlCenterCommands.command(
            for: .setWiFiEnabled(true), withSudoPassword: true)
        let bluetooth = MachineControlCenterCommands.command(
            for: .setBluetoothEnabled(true), withSudoPassword: true)

        #expect(
            brightness.contains(
                "brightnessctl -c backlight set \"${level}%\" >/dev/null 2>&1 </dev/null"))
        #expect(wifi.contains("nmcli radio wifi on >/dev/null 2>&1 </dev/null"))
        #expect(
            wifi.contains("networksetup -listallhardwareports </dev/null 2>/dev/null"))
        #expect(bluetooth.contains("bluetoothctl power on >/dev/null 2>&1 </dev/null"))
        #expect(bluetooth.contains("/usr/bin/sudo -S -p '' sh -c"))
        #expect(bluetooth.contains("exec </dev/null"))
    }

    @Test func usesLocalMacAuthorizationForWiFi() {
        let command = MachineControlCenterCommands.command(
            for: .setWiFiEnabled(false), withSudoPassword: false,
            usingLocalAuthorization: true)

        #expect(command.contains("with administrator privileges"))
        #expect(command.contains("EDITH_WIFI_DEVICE=\"$wifi_device\""))
        #expect(
            !command.contains(
                "/usr/bin/sudo -n sh -c 'exec </dev/null; exec networksetup"))
    }

    @Test func verifiesBluetoothAndActiveGnomeState() {
        let bluetooth = MachineControlCenterCommands.command(
            for: .setBluetoothEnabled(true), withSudoPassword: true)
        let doNotDisturb = MachineControlCenterCommands.command(
            for: .setDoNotDisturb(true), withSudoPassword: false)

        #expect(bluetooth.contains("Powered: $2"))
        #expect(bluetooth.contains("Soft blocked: $4"))
        #expect(bluetooth.contains("rfkill unblock bluetooth"))
        #expect(bluetooth.contains("Bluetooth state did not change."))
        #expect(doNotDisturb.contains("NameHasOwner org.gnome.Shell"))
        #expect(doNotDisturb.contains("Do Not Disturb setting did not change."))
        #expect(
            MachineControlCenterCommands.statusCommand.contains(
                "NameHasOwner org.gnome.Shell"))
    }

    @Test func marksOnlyDisruptiveNetworkOperations() {
        let wifiOff = MachineControlCenterCommands.command(
            for: .setWiFiEnabled(false), withSudoPassword: true)
        let wifiOn = MachineControlCenterCommands.command(
            for: .setWiFiEnabled(true), withSudoPassword: true)
        let airplaneOn = MachineControlCenterCommands.command(
            for: .setAirplaneMode(true), withSudoPassword: true)
        let markedError = SSHConnectionError.commandFailed(
            command: "control", status: 255,
            stderr: "\(MachineControlCenterCommands.disruptiveMarker)\nconnection closed")
        let unmarkedError = SSHConnectionError.commandFailed(
            command: "control", status: 255, stderr: "connection closed")

        #expect(wifiOff.contains(MachineControlCenterCommands.disruptiveMarker))
        #expect(!wifiOn.contains(MachineControlCenterCommands.disruptiveMarker))
        #expect(airplaneOn.contains(MachineControlCenterCommands.disruptiveMarker))
        #expect(
            wifiOff.contains(
                "\(MachineControlCenterCommands.disruptiveMarker) >&2; exec networksetup"))
        #expect(
            airplaneOn.contains(
                "\(MachineControlCenterCommands.disruptiveMarker) >&2; exec rfkill"))
        #expect(MachineControlCenterCommands.disruptiveOperationStarted(markedError))
        #expect(!MachineControlCenterCommands.disruptiveOperationStarted(unmarkedError))
    }

    @Test func keepsPreferredBackendsAheadOfFallbacks() throws {
        let status = MachineControlCenterCommands.statusCommand
        let wpctl = try #require(status.range(of: "command -v wpctl"))
        let pactl = try #require(status.range(of: "command -v pactl"))
        let amixer = try #require(status.range(of: "command -v amixer"))
        let nmcli = try #require(status.range(of: "command -v nmcli"))
        let wifiRfkill = try #require(
            status.range(of: "command -v rfkill", range: nmcli.upperBound..<status.endIndex))
        let bluetoothStart = try #require(status.range(of: "bluetooth_done=0"))
        let bluetoothctl = try #require(
            status.range(
                of: "command -v bluetoothctl",
                range: bluetoothStart.upperBound..<status.endIndex))
        let bluetoothRfkill = try #require(
            status.range(
                of: "command -v rfkill", range: bluetoothctl.upperBound..<status.endIndex))

        #expect(wpctl.lowerBound < pactl.lowerBound)
        #expect(pactl.lowerBound < amixer.lowerBound)
        #expect(nmcli.lowerBound < wifiRfkill.lowerBound)
        #expect(bluetoothctl.lowerBound < bluetoothRfkill.lowerBound)
        #expect(status.contains("brightnessctl -c backlight"))
        #expect(status.contains("/sys/class/power_supply/*"))
        #expect(status.contains("/sys/class/backlight/*"))
        #expect(status.contains("brightnessctl -d \"$keyboard_name\""))
        #expect(status.contains("/sys/class/leds/*"))
    }

    @Test func includesSupportedPlatformToolsAndDesktopEnvironmentDefaults() {
        let status = MachineControlCenterCommands.statusCommand

        #expect(status.contains("XDG_RUNTIME_DIR"))
        #expect(status.contains("DBUS_SESSION_BUS_ADDRESS"))
        #expect(
            status.contains(
                "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/local/sbin"
            ))
        #expect(status.contains("gsettings get org.gnome.desktop.notifications show-banners"))
        #expect(status.contains("brightness -l"))
        #expect(status.contains("pmset -g batt"))
        #expect(status.contains("osascript -e"))
        #expect(status.contains("networksetup -getairportpower"))
        #expect(status.contains("blueutil -p"))
        #expect(status.contains("command -v mac-brightnessctl"))
        #expect(status.contains("$1 == \"Current\" && $2 == \"brightness:\""))
    }

    @Test func emitsValidShellCommands() throws {
        let actions: [MachineControlAction] = [
            .setBrightness(50),
            .setVolume(50),
            .setKeyboardBacklight(50),
            .setMuted(true),
            .setWiFiEnabled(true),
            .setBluetoothEnabled(true),
            .setAirplaneMode(true),
            .setDoNotDisturb(true),
        ]
        let commands =
            [MachineControlCenterCommands.statusCommand]
            + actions.flatMap { action in
                [
                    MachineControlCenterCommands.command(
                        for: action, withSudoPassword: false),
                    MachineControlCenterCommands.command(
                        for: action, withSudoPassword: true),
                ]
            }
            + [
                MachineControlCenterCommands.command(
                    for: .setWiFiEnabled(true), withSudoPassword: false,
                    usingLocalAuthorization: true)
            ]

        for command in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-n", "-c", command]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }
}

@Suite struct MachineControlOperationTests {
    @Test func descriptorsAreUniqueCompleteAndClassified() {
        let descriptors = MachineControlOperation.allCases.map(\.descriptor)
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
        #expect(descriptors.allSatisfy { $0.cli.starts(with: ["machines", "control"]) })
        #expect(MachineControlOperation.status.descriptor.effect == .read)
        #expect(MachineControlOperation.wifi.descriptor.requiresPreview)
        #expect(MachineControlOperation.airplane.descriptor.requiresPreview)
        #expect(!MachineControlOperation.volume.descriptor.requiresPreview)
        #expect(
            UserOperationCatalog.descriptors.filter {
                $0.cli.starts(with: ["machines", "control"])
            } == descriptors)
    }

    @Test func statusUsesTheSharedCommandAndParsesItsResult() async throws {
        var command = ""
        var timeout: TimeInterval = 0
        let result = await MachineControlOperationExecution.status { next, stdin, seconds in
            command = next
            timeout = seconds
            #expect(stdin == nil)
            return .success("EDITH_CONTROL_PLATFORM=linux\nEDITH_CONTROL_VOLUME=37\n")
        }
        let snapshot = try result.get()
        #expect(command == MachineControlCenterCommands.statusCommand)
        #expect(timeout == 20)
        #expect(snapshot.platform == .linux)
        #expect(snapshot.volume == 37)
    }

    @Test func windowsStatusUsesTheNativeCommand() async throws {
        var command = ""
        let result = await MachineControlOperationExecution.status(platform: .windows) {
            next, _, _ in
            command = next
            return .success("EDITH_CONTROL_PLATFORM=windows\nEDITH_CONTROL_VOLUME=37\n")
        }

        let snapshot = try result.get()
        #expect(command == WindowsMachineControlCommands.status)
        #expect(snapshot.platform == .windows)
        #expect(snapshot.volume == 37)
    }

    @Test func mutationsUseTheSharedBuilderAndTimeout() async throws {
        var command = ""
        var timeout: TimeInterval = 0
        let result = await MachineControlOperationExecution.perform(
            .setVolume(41), machineID: Machine.localID, isLocal: true,
            platform: .darwin
        ) { next, stdin, seconds in
            command = next
            timeout = seconds
            #expect(stdin == nil)
            return .success("")
        }
        _ = try result.get()
        #expect(command.contains("output volume 41"))
        #expect(timeout == 30)
    }

    @Test func actionMetadataMatchesOnlyDisconnectingChanges() {
        #expect(MachineControlAction.setWiFiEnabled(false).isDisruptive)
        #expect(MachineControlAction.setAirplaneMode(true).isDisruptive)
        #expect(!MachineControlAction.setWiFiEnabled(true).isDisruptive)
        #expect(!MachineControlAction.setAirplaneMode(false).isDisruptive)
        #expect(MachineControlAction.setMuted(true).operation == .mute)
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

    @Test func cancellingAStalledDownloadTerminatesItsProcessAndRemovesThePartialFile() async throws
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec sleep 300"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-stalled-download-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: localURL)
        try process.run()
        let task = Task {
            try await SSHConnection.receiveDownload(
                process: process, reader: pipe.fileHandleForReading, output: output,
                localURL: localURL)
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: localURL.path))
    }

    @Test func cancellingABlockedUploadClosesItsPipeAndTerminatesItsProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec sleep 300"]
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-stalled-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: localURL) }
        try Data(repeating: 1, count: 2 * 1024 * 1024).write(to: localURL)
        let input = try FileHandle(forReadingFrom: localURL)
        try process.run()
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            try await SSHConnection.sendUpload(
                process: process, input: input, writer: pipe.fileHandleForWriting,
                timeout: 30)
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!process.isRunning)
        #expect(clock.now - started < .seconds(3))
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
                MachineReconnect.state(afterFailures: failures, reason: "nope")
                    == .reconnecting(message: "nope"))
        }
        #expect(
            MachineReconnect.state(
                afterFailures: MachineReconnect.quietFailures + 1, reason: "Connection refused.")
                == .failed(message: "Connection refused.", recoverable: true))
    }

    @Test func aQuietReconnectIsBusyAndRetryableButNotConnected() {
        let state = MachineConnectionState.reconnecting(message: "Connection timed out.")
        #expect(state.isBusy)
        #expect(state.isRetryable == false)
        #expect(state.isConnected == false)
        #expect(state.failureMessage == "Connection timed out.")
        #expect(MachineConnectionState.connecting.isRetryable == false)
        #expect(MachineConnectionState.disconnected.isRetryable == false)
    }

    @Test func onlyRecoverableFailuresCanRetry() {
        let recoverable = MachineConnectionState.failed(
            message: "Connection refused.", recoverable: true)
        let terminal = MachineConnectionState.failed(
            message: "Edith connects to remote Macs only.", recoverable: false)

        #expect(recoverable.isRetryable)
        #expect(terminal.isRetryable == false)
        #expect(terminal.failureMessage == "Edith connects to remote Macs only.")
    }
}
