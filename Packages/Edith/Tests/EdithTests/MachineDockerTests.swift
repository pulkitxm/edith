import Foundation
import Observation
import Testing

@testable import EdithKit

@Suite struct DockerParsingTests {
    private let psOutput = """
        {"Command":"\\"docker-entrypoint.s…\\"","CreatedAt":"2026-08-01 10:23:45 +0000 UTC",\
        "ID":"a1b2c3d4e5f60000000000000000000000000000000000000000000000000000",\
        "Image":"postgres:16","Labels":"com.docker.compose.project=api,\
        com.docker.compose.service=db","Names":"api-db-1",\
        "Ports":"0.0.0.0:5432->5432/tcp, :::5432->5432/tcp","State":"running",\
        "Status":"Up 2 hours (healthy)"}
        {"Command":"\\"nginx\\"","CreatedAt":"2026-07-30 08:00:00 +0000 UTC",\
        "ID":"ffffeeee111122223333444455556666777788889999aaaabbbbccccddddeeee",\
        "Image":"nginx:alpine","Labels":"","Names":"web","Ports":"","State":"exited",\
        "Status":"Exited (0) 3 days ago"}
        """

    @Test func parsesContainers() {
        let containers = DockerParsing.containers(psOutput: psOutput)
        #expect(containers.count == 2)
        let db = containers[0]
        #expect(db.displayName == "api-db-1")
        #expect(db.image == "postgres:16")
        #expect(db.state == .running)
        #expect(db.health == .healthy)
        #expect(db.composeProject == "api")
        #expect(db.composeService == "db")
        #expect(db.shortID == "a1b2c3d4e5f6")
        let web = containers[1]
        #expect(web.state == .exited)
        #expect(web.health == .none)
        #expect(web.ports.isEmpty)
        #expect(web.composeProject == nil)
    }

    @Test func prefersExplicitHealthStatusField() {
        let output = """
            {"ID":"abc","Names":"db","Image":"postgres:17","State":"running",\
            "Status":"Up 19 hours (healthy)","HealthStatus":"unhealthy","Labels":"","Ports":""}
            """
        #expect(DockerParsing.containers(psOutput: output).first?.health == .unhealthy)
        #expect(DockerParsing.parseHealth(status: "Up 2 hours", healthStatus: "") == .none)
        #expect(
            DockerParsing.parseHealth(status: "Up 2 hours (health: starting)") == .starting)
    }

    @Test func deduplicatesBracketedIPv6PortEntries() {
        let ports = DockerParsing.parsePorts("0.0.0.0:5433->5432/tcp, [::]:5433->5432/tcp")
        #expect(ports.count == 1)
        #expect(ports[0].hostPort == 5433)
        #expect(ports[0].containerPort == 5432)
    }

    @Test func deduplicatesIPv4AndIPv6PortEntries() {
        let ports = DockerParsing.parsePorts("0.0.0.0:5432->5432/tcp, :::5432->5432/tcp")
        #expect(ports.count == 1)
        #expect(ports[0].hostPort == 5432)
        #expect(ports[0].containerPort == 5432)
        #expect(ports[0].proto == "tcp")
        #expect(ports[0].browserURL?.absoluteString == "http://localhost:5432")
    }

    @Test func parsesUnpublishedPorts() {
        let ports = DockerParsing.parsePorts("80/tcp, 443/tcp")
        #expect(ports.map(\.containerPort) == [80, 443])
        #expect(ports.allSatisfy { $0.hostPort == nil })
        #expect(ports[0].browserURL == nil)
        #expect(ports[0].displayName == "80/tcp")
    }

    @Test func parsesBinaryAndDecimalSizes() {
        #expect(DockerParsing.parseSize("7.75MiB") == Int64(7.75 * 1_048_576))
        #expect(DockerParsing.parseSize("15.61GiB") == Int64(15.61 * 1_073_741_824))
        #expect(DockerParsing.parseSize("125MB") == 125_000_000)
        #expect(DockerParsing.parseSize("658kB") == 658_000)
        #expect(DockerParsing.parseSize("0B") == 0)
        #expect(DockerParsing.parseSize("N/A") == nil)
        #expect(DockerParsing.parseSize("--") == nil)
    }

    @Test func parsesPercentagesIncludingMulticoreAndSentinels() {
        #expect(DockerParsing.parsePercent("1.53%") == 1.53)
        #expect(DockerParsing.parsePercent("235.00%") == 235.0)
        #expect(DockerParsing.parsePercent("--") == nil)
    }

    @Test func mergesStatsIntoContainers() {
        let stats = """
            {"ID":"a1b2c3d4e5f6","Name":"api-db-1","CPUPerc":"1.53%","MemPerc":"0.05%",\
            "MemUsage":"7.75MiB / 15.61GiB","NetIO":"658kB / 45.2MB","BlockIO":"12.3MB / 0B",\
            "PIDs":"4"}
            """
        let merged = DockerParsing.applyStats(
            stats, to: DockerParsing.containers(psOutput: psOutput))
        #expect(merged[0].cpuPercent == 1.53)
        #expect(merged[0].memUsedBytes == Int64(7.75 * 1_048_576))
        #expect(merged[0].memLimitBytes == Int64(15.61 * 1_073_741_824))
        #expect(merged[0].netRxBytes == 658_000)
        #expect(merged[1].cpuPercent == nil)
    }

    @Test func parsesImagesAndFlagsDangling() {
        let output = """
            {"ID":"sha256:aaaa1111bbbb2222","Repository":"nginx","Tag":"alpine",\
            "CreatedSince":"5 days ago","Size":"48.2MB"}
            {"ID":"sha256:cccc3333","Repository":"<none>","Tag":"<none>",\
            "CreatedSince":"2 weeks ago","Size":"1.1GB"}
            """
        let images = DockerParsing.images(output)
        #expect(images.count == 2)
        #expect(images[0].displayName == "nginx:alpine")
        #expect(images[0].sizeBytes == 48_200_000)
        #expect(images[0].shortID == "aaaa1111bbbb")
        #expect(!images[0].dangling)
        #expect(images[1].dangling)
        #expect(images[1].displayName == "<none>:<none>")
    }

    @Test func parsesVolumesAndMergesSystemDFDetails() {
        let volumes = DockerParsing.volumes(
            """
            {"Name":"api_pgdata","Driver":"local","Mountpoint":"/var/lib/docker/volumes/api_pgdata"}
            """)
        #expect(volumes.count == 1)
        #expect(!volumes[0].inUse)
        let details = DockerParsing.volumeDetails(
            systemDFOutput: """
                {"Volumes":[{"Name":"api_pgdata","Links":2,"Size":"312MB"}]}
                """)
        #expect(details["api_pgdata"]?.0 == 312_000_000)
        #expect(details["api_pgdata"]?.1 == 2)
    }

    @Test func parsesDiskUsageReclaimable() {
        let usage = DockerParsing.diskUsage(
            """
            {"Type":"Images","TotalCount":"12","Active":"5","Size":"2.631GB",\
            "Reclaimable":"2.498GB (94%)"}
            """)
        #expect(usage.count == 1)
        #expect(usage[0].sizeBytes == 2_631_000_000)
        #expect(usage[0].reclaimableBytes == 2_498_000_000)
        #expect(usage[0].totalCount == 12)
    }

    @Test func ignoresNonJSONNoise() {
        let output = """
            Last login: Sun Aug 16 19:20:00 on ttys001
            {"ID":"abc","Repository":"nginx","Tag":"latest","Size":"1MB","CreatedSince":"now"}
            """
        #expect(DockerParsing.images(output).count == 1)
    }

    @Test func splitsTimestampedLogLines() {
        let line = DockerParsing.splitLogLine(
            "2026-08-06T12:34:56.789012345Z starting server on :3000", index: 0, isStderr: false)
        #expect(line.timestamp == "2026-08-06T12:34:56.789012345Z")
        #expect(line.text == "starting server on :3000")

        let plain = DockerParsing.splitLogLine("no timestamp here", index: 1, isStderr: true)
        #expect(plain.timestamp == nil)
        #expect(plain.text == "no timestamp here")
        #expect(plain.isStderr)
    }

    @Test func detectsAvailabilityStates() {
        let ok = DockerParsing.availability(
            versionOutput: "{\"Client\":{\"Version\":\"27.0\"},\"Server\":{\"Version\":\"27.0\"}}",
            versionStderr: "", status: 0)
        #expect(ok.isAvailable)

        let denied = DockerParsing.availability(
            versionOutput: "",
            versionStderr: "permission denied while trying to connect to the Docker daemon socket",
            status: 1)
        #expect(denied.status == .permissionDenied)

        let missing = DockerParsing.availability(
            versionOutput: "", versionStderr: "bash: docker: command not found", status: 127)
        #expect(missing.status == .missing)

        let down = DockerParsing.availability(
            versionOutput: "",
            versionStderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock.",
            status: 1)
        #expect(down.status == .daemonDown(message: "The Docker daemon is not running."))
    }
}

@Suite struct DockerCommandsTests {
    @Test func usesGoTemplateJSONFormatEverywhere() {
        #expect(DockerCommands.images().contains("'{{json .}}'"))
        #expect(DockerCommands.volumes().contains("'{{json .}}'"))
        #expect(!DockerCommands.images().contains("--format json"))
    }

    @Test func batchesContainersAndStatsWithSeparator() {
        let command = DockerCommands.containersWithStats()
        #expect(command.contains("docker ps -a --no-trunc"))
        #expect(command.contains(DockerCommands.listSeparator))
        #expect(command.contains("docker stats --no-stream"))
    }

    @Test func quotesIdentifiersInLifecycleCommands() {
        #expect(DockerCommands.lifecycle("stop", id: "web") == "docker stop -t 10 web")
        #expect(DockerCommands.lifecycle("rm", id: "a b") == "docker rm -f 'a b'")
        #expect(DockerCommands.lifecycle("start", id: "$(evil)") == "docker start '$(evil)'")
    }

    @Test func execShellFallsBackFromBashToSh() {
        let command = DockerCommands.execShell(containerID: "web")
        #expect(command.hasPrefix("docker exec -it web sh -c "))
        #expect(command.contains("command -v bash"))
        #expect(command.contains("exec sh"))
    }

    @Test func logsCommandCarriesTimestampsAndTail() {
        let command = DockerCommands.logs("web", tail: 200, follow: true)
        #expect(command == "docker logs --timestamps --tail 200 --follow web")
    }
}

@Suite struct FileListingTests {
    @Test func parsesFindOutput() {
        let sep = FileListing.separator
        let output = [
            "d\(sep)4096\(sep)1754000000.0\(sep)755\(sep)projects\(sep)",
            "f\(sep)2048\(sep)1754000100.5\(sep)644\(sep)notes.md\(sep)",
            "l\(sep)12\(sep)1754000200.0\(sep)777\(sep)link\(sep)/etc/hosts",
        ].joined(separator: "\n")
        let entries = FileListing.parse(output: output, parent: "/home/pulkit")
        #expect(entries.map(\.name) == ["projects", "link", "notes.md"])
        #expect(entries[0].kind == .directory)
        #expect(entries[0].path == "/home/pulkit/projects")
        #expect(entries[1].kind == .symlink)
        #expect(entries[1].linkTarget == "/etc/hosts")
        #expect(entries[2].sizeBytes == 2048)
        #expect(entries[2].modified == Date(timeIntervalSince1970: 1_754_000_100.5))
    }

    @Test func sortsDirectoriesFirstThenCaseInsensitively() {
        let sep = FileListing.separator
        let output = [
            "f\(sep)1\(sep)1\(sep)644\(sep)zeta.txt\(sep)",
            "f\(sep)1\(sep)1\(sep)644\(sep)Alpha.txt\(sep)",
            "d\(sep)1\(sep)1\(sep)755\(sep)src\(sep)",
        ].joined(separator: "\n")
        let entries = FileListing.parse(output: output, parent: "/x")
        #expect(entries.map(\.name) == ["src", "Alpha.txt", "zeta.txt"])
    }

    @Test func fallsBackToLSParsing() {
        let output = """
            total 12
            drwxr-xr-x 3 1000 1000 4096 1754000000 projects
            -rw-r--r-- 1 1000 1000 2048 1754000100 notes.md
            lrwxrwxrwx 1 1000 1000 12 1754000200 link -> /etc/hosts
            """
        let entries = FileListing.parse(output: output, parent: "/home/pulkit")
        #expect(entries.map(\.name) == ["projects", "link", "notes.md"])
        #expect(entries[0].kind == .directory)
        #expect(entries[1].linkTarget == "/etc/hosts")
        #expect(entries[2].sizeBytes == 2048)
    }

    @Test func joinsAndWalksPaths() {
        #expect(FileListing.join(parent: "/", name: "etc") == "/etc")
        #expect(FileListing.join(parent: "/home", name: "pulkit") == "/home/pulkit")
        #expect(FileListing.join(parent: "/home/", name: "pulkit") == "/home/pulkit")
        #expect(FileListing.parentPath(of: "/home/pulkit") == "/home")
        #expect(FileListing.parentPath(of: "/home") == "/")
        #expect(FileListing.parentPath(of: "/") == nil)
    }

    @Test func buildsBreadcrumbs() {
        let crumbs = FileListing.breadcrumbs(for: "/home/pulkit/code")
        #expect(crumbs.map(\.name) == ["/", "home", "pulkit", "code"])
        #expect(crumbs.map(\.path) == ["/", "/home", "/home/pulkit", "/home/pulkit/code"])
    }

    @Test func quotesPathsWithSpaces() {
        let command = FileListing.command(path: "/mnt/My Files", showHidden: true)
        #expect(command.contains("'/mnt/My Files'"))
    }

    @Test func detectsHiddenEntries() {
        let entry = RemoteFileEntry(
            name: ".bashrc", path: "/home/p/.bashrc", kind: .file, sizeBytes: 10)
        #expect(entry.isHidden)
        #expect(entry.fileExtension == "bashrc")
    }
}

@Suite struct FilePreviewKindTests {
    @Test func routesByExtension() {
        #expect(FilePreviewKind.kind(forExtension: "swift") == .text)
        #expect(FilePreviewKind.kind(forExtension: "JSON") == .text)
        #expect(FilePreviewKind.kind(forExtension: "png") == .image)
        #expect(FilePreviewKind.kind(forExtension: "pdf") == .pdf)
        #expect(FilePreviewKind.kind(forExtension: "mp4") == .media)
        #expect(FilePreviewKind.kind(forExtension: "mkv") == .unsupported)
        #expect(FilePreviewKind.kind(forExtension: "webm") == .unsupported)
        #expect(FilePreviewKind.kind(forExtension: "docx") == .quickLook)
        #expect(FilePreviewKind.kind(forExtension: "") == .quickLook)
    }

    @Test func recognizesExtensionlessTextFiles() {
        #expect(FilePreviewKind.isPlainTextName("Dockerfile"))
        #expect(FilePreviewKind.isPlainTextName("/etc/Makefile"))
        #expect(!FilePreviewKind.isPlainTextName("binary"))
    }
}

@Suite struct ByteFormatterTests {
    @Test func formatsBytes() {
        #expect(ByteFormatter.string(0) == "0 B")
        #expect(ByteFormatter.string(512) == "512 B")
        #expect(ByteFormatter.string(2048) == "2.0 KB")
        #expect(ByteFormatter.string(1_500_000) == "1.5 MB")
        #expect(ByteFormatter.string(250_000_000) == "250 MB")
    }

    @Test func formatsRatesAndDurations() {
        #expect(ByteFormatter.rate(1_500_000) == "1.5 MB/s")
        #expect(ByteFormatter.rate(-5) == "0 B/s")
        #expect(ByteFormatter.duration(90) == "1m")
        #expect(ByteFormatter.duration(3700) == "1h 1m")
        #expect(ByteFormatter.duration(200_000) == "2d 7h")
    }
}

@Suite struct MachineFactsTests {
    @Test func parsesWhoOutput() {
        let who = MachineFacts.parseWho(
            "pulkit   pts/0        2026-08-06 10:11 (192.168.1.9)\nroot     tty1  2026-08-05 09:00")
        #expect(who.count == 2)
        #expect(who[0].hasPrefix("pulkit on pts/0 since 2026-08-06 10:11"))
    }

    @Test func parsesUpdateCountsAndSentinel() {
        #expect(MachineFacts.parseUpdates("12\n") == 12)
        #expect(MachineFacts.parseUpdates("0") == 0)
        #expect(MachineFacts.parseUpdates("-1") == nil)
        #expect(MachineFacts.parseUpdates("garbage") == nil)
    }

    @Test func validatesMACAddress() {
        #expect(MachineFacts.parseMACAddress("AA:BB:CC:DD:EE:FF\n") == "aa:bb:cc:dd:ee:ff")
        #expect(MachineFacts.parseMACAddress("not-a-mac") == nil)
    }

    @Test func theWakeAddressSupportsMacOSAndLinuxInterfaces() {
        let command = MachineFacts.macAddressCommand
        #expect(command.contains("networksetup -listallhardwareports"))
        #expect(command.contains("Hardware Port: (Ethernet|Wi-Fi)"))
        #expect(command.contains("Ethernet Address:"))
        #expect(command.contains("ip -o link show up"))
        #expect(command.contains("link/ether"))
    }

    @Test func updateCountsSupportMacOSAndLinuxPackageManagers() {
        let command = MachineFacts.updatesCommand
        #expect(command.contains("softwareupdate -l"))
        #expect(command.contains("apt list --upgradable"))
        #expect(command.contains("dnf -q check-update"))
        #expect(command.contains("pacman -Qu"))
    }

    @Test func buildsWakeOnLANMagicPacket() {
        let packet = WakeOnLAN.magicPacket(macAddress: "aa:bb:cc:dd:ee:ff")
        #expect(packet?.count == 102)
        #expect(packet?.prefix(6) == Data(repeating: 0xFF, count: 6))
        #expect(WakeOnLAN.magicPacket(macAddress: "bogus") == nil)
    }
}

@Suite struct PowerCommandsTests {
    @Test func macPowerCommandsUseShutdown() {
        #expect(PowerCommands.reboot().contains("shutdown -r now"))
        #expect(PowerCommands.shutdown().contains("shutdown -h now"))
    }

    @Test func aStoredSudoPasswordUsesStandardInput() {
        let commands = [
            PowerCommands.reboot(withSudoPassword: true),
            PowerCommands.shutdown(withSudoPassword: true),
        ]
        for command in commands {
            #expect(command.contains("sudo -S"))
            #expect(command.contains("-p ''"))
        }
    }
}

@Suite @MainActor struct MachineSessionHistoryTests {
    private func session() -> MachineSession {
        MachineSession(machine: Machine(name: "This Mac", host: "localhost"), local: true)
    }

    private func sample(_ value: Double) -> MachineSample {
        MachineSample(
            ts: value, dt: 2, cpu: MachineCPU(total: value),
            mem: MachineMemory(totalKB: 100, availKB: 100 - Int64(value), usedKB: Int64(value)),
            disk: MachineDiskIO(readBps: value * 2, writeBps: value * 3),
            net: MachineNetwork(rxBps: value * 4, txBps: value * 5))
    }

    @Test func historyKeepsFixedWindow() {
        var history: [Double] = []
        for value in 0..<80 {
            history = MachineSession.appending(Double(value), to: history)
        }
        #expect(history.count == MachineSession.historyLength)
        #expect(history.first == 20)
        #expect(history.last == 79)
    }

    @Test func oneSamplePublishesAMetricsUpdate() {
        let session = session()
        var updates = 0
        withObservationTracking {
            _ = session.sample
        } onChange: {
            updates += 1
        }
        session.apply(sample: sample(10))
        #expect(updates == 1)
    }

    @Test func oneMetricsUpdateCarriesEveryHistory() {
        let session = session()
        session.apply(sample: sample(10))
        session.apply(sample: sample(20))
        #expect(session.sample?.cpu.total == 20)
        #expect(session.cpuHistory.last == 20)
        #expect(session.memHistory.last == 20)
        #expect(session.diskReadHistory.last == 40)
        #expect(session.diskWriteHistory.last == 60)
        #expect(session.netRxHistory.last == 80)
        #expect(session.netTxHistory.last == 100)
    }
}

@Suite @MainActor struct MachineSessionResourceTests {
    private func session() -> MachineSession {
        MachineSession(machine: Machine(name: "This Mac", host: "localhost"), local: true)
    }

    @Test func dockerUsesTheBackgroundCadenceUntilObserved() {
        let session = session()
        #expect(
            session.currentDockerPollInterval
                == MachineResourcePolicy.backgroundDockerPollInterval)
        session.beginDockerObservation()
        #expect(
            session.currentDockerPollInterval
                == MachineResourcePolicy.foregroundDockerPollInterval)
    }

    @Test func dockerStaysForegroundedUntilEveryObserverLeaves() {
        let session = session()
        session.beginDockerObservation()
        session.beginDockerObservation()
        session.endDockerObservation()
        #expect(
            session.currentDockerPollInterval
                == MachineResourcePolicy.foregroundDockerPollInterval)
        session.endDockerObservation()
        #expect(
            session.currentDockerPollInterval
                == MachineResourcePolicy.backgroundDockerPollInterval)
    }

    @Test func unmatchedDisappearCannotMakeTheObserverCountNegative() {
        let session = session()
        session.endDockerObservation()
        session.endDockerObservation()
        #expect(
            session.currentDockerPollInterval
                == MachineResourcePolicy.backgroundDockerPollInterval)
    }
}

@Suite struct DockerDetailParsingTests {
    @Test func parsesTopOutput() {
        let output = """
            PID    USER   %CPU  %MEM   RSS     COMMAND
            1      root   0.5   1.2    45678   /usr/bin/postgres -D /var/lib/data
            42     redis  0.0   0.3    12345   redis-server *:6379
            """
        let processes = DockerParsing.processes(output)
        #expect(processes.count == 2)
        #expect(processes[0].pid == "1")
        #expect(processes[0].user == "root")
        #expect(processes[0].command == "/usr/bin/postgres -D /var/lib/data")
        #expect(processes[1].command == "redis-server *:6379")
    }

    @Test func topWithoutRowsIsEmpty() {
        #expect(DockerParsing.processes("PID USER %CPU %MEM RSS COMMAND").isEmpty)
        #expect(DockerParsing.processes("").isEmpty)
    }

    @Test func parsesInspectSummary() {
        let output = """
            [{"Created":"2026-08-01T10:00:00Z",
            "Config":{"Image":"postgres:17","Cmd":["postgres","-c","fsync=off"],
            "Env":["POSTGRES_PASSWORD=secret","LANG=C"],"Labels":{"role":"db"}},
            "HostConfig":{"RestartPolicy":{"Name":"unless-stopped"}},
            "NetworkSettings":{"Networks":{"api_default":{}}},
            "Mounts":[{"Source":"/var/lib/pg","Destination":"/data"}]}]
            """
        guard let summary = DockerParsing.inspectSummary(output) else {
            Issue.record("expected a summary")
            return
        }
        #expect(summary.image == "postgres:17")
        #expect(summary.command == "postgres -c fsync=off")
        #expect(summary.restartPolicy == "unless-stopped")
        #expect(summary.networks == ["api_default"])
        #expect(summary.mounts == ["/var/lib/pg → /data"])
        #expect(summary.environment.contains("LANG=C"))
        #expect(summary.labels["role"] == "db")
    }

    @Test func inspectHandlesGarbage() {
        #expect(DockerParsing.inspectSummary("not json") == nil)
        #expect(DockerParsing.inspectSummary("[]") == nil)
    }

    @Test func parsesComposeProjectsFromArrayOrLines() {
        #expect(
            DockerParsing.composeProjects("[{\"Name\":\"api\"},{\"Name\":\"web\"}]")
                == ["api", "web"])
        #expect(
            DockerParsing.composeProjects("{\"Name\":\"api\"}\n{\"Name\":\"web\"}")
                == ["api", "web"])
    }

    @Test func pruneAndDetailCommandsAreShaped() {
        #expect(DockerCommands.prune("images") == "docker image prune -af")
        #expect(DockerCommands.prune("volumes") == "docker volume prune -f")
        #expect(DockerCommands.inspectRaw("a b").contains("'a b'"))
        #expect(DockerCommands.top("web").contains("docker top web"))
        #expect(
            DockerCommands.listFiles(containerID: "web", path: "/etc")
                .contains("docker exec web sh -c"))
        #expect(
            DockerCommands.composeAction("up -d", project: "api", directory: "/srv/api")
                .contains("--project-directory /srv/api"))
    }
}

@Suite struct DockerTopParsingTests {
    @Test func readsTheExtendedFormat() {
        let output = """
            PID                 USER                %CPU                %MEM                RSS                 COMMAND
            216303              70                  0.0                 0.0                 26552               postgres
            216475              70                  0.0                 0.1                 91924               postgres: checkpointer
            """
        let rows = DockerParsing.processes(output)
        #expect(rows.count == 2)
        #expect(rows[0].pid == "216303")
        #expect(rows[0].user == "70")
        #expect(rows[0].cpu == "0.0")
        #expect(rows[0].memory == "0.0")
        #expect(rows[0].command == "postgres")
        #expect(rows[1].command == "postgres: checkpointer")
    }

    @Test func readsThePlainFallbackWithoutShiftingColumns() {
        let output = """
            UID                 PID                 PPID                C                   STIME               TTY                 TIME                CMD
            70                  216303              216277              0                   Aug05               ?                   00:00:07            postgres
            70                  216475              216303              0                   Aug05               ?                   00:00:00            postgres: checkpointer
            """
        let rows = DockerParsing.processes(output)
        #expect(rows.count == 2)
        #expect(rows[0].pid == "216303")
        #expect(rows[1].pid == "216475")
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows[0].user == "70")
        #expect(rows[0].command == "postgres")
        #expect(rows[1].command == "postgres: checkpointer")
    }
}

@Suite struct ContainerListingFallbackTests {
    @Test func parsesTheNonGnuLsFallback() {
        let output = """
            drwxr-xr-x 2 root root 4096 Aug  5 10:22 bin
            -rw-r--r-- 1 root root  220 Aug  5 10:22 hosts
            """
        let entries = FileListing.parse(output: output, parent: "/etc")
        #expect(entries.count == 2)
        #expect(entries.map(\.name).sorted() == ["bin", "hosts"])
        #expect(entries.first { $0.name == "bin" }?.isDirectory == true)
        #expect(entries.first { $0.name == "hosts" }?.sizeBytes == 220)
    }

    @Test func stillParsesEpochStamps() {
        let output = "-rw-r--r-- 1 root root 220 1754390000 hosts"
        let entries = FileListing.parse(output: output, parent: "/etc")
        #expect(entries.count == 1)
        #expect(entries[0].name == "hosts")
        #expect(entries[0].modified != nil)
    }
}

@Suite struct DockerGroupPlanTests {
    private func container(_ name: String, _ state: DockerContainerState) -> DockerContainer {
        DockerContainer(
            id: name, names: [name], image: "img", command: "cmd", state: state, status: "")
    }

    @Test func aMixedGroupCanBothStartAndStop() {
        let plan = DockerGroupPlan(containers: [
            container("postgres", .running),
            container("clickhouse", .running),
            container("redis", .exited),
        ])
        #expect(plan.isMixed)
        #expect(plan.startable.map(\.id) == ["redis"])
        #expect(plan.stoppable.map(\.id) == ["postgres", "clickhouse"])
    }

    @Test func aFullyStoppedGroupOnlyStarts() {
        let plan = DockerGroupPlan(containers: [
            container("a", .exited), container("b", .created), container("c", .dead),
        ])
        #expect(plan.canStart)
        #expect(!plan.canStop)
        #expect(plan.startable.count == 3)
    }

    @Test func aFullyRunningGroupOnlyStops() {
        let plan = DockerGroupPlan(containers: [
            container("a", .running), container("b", .restarting),
        ])
        #expect(!plan.canStart)
        #expect(plan.canStop)
        #expect(plan.stoppable.count == 2)
    }

    @Test func pausedContainersStopButNeverStart() {
        let plan = DockerGroupPlan(containers: [container("a", .paused)])
        #expect(!plan.canStart)
        #expect(plan.stoppable.map(\.id) == ["a"])
    }

    @Test func transientStatesAreLeftAlone() {
        let plan = DockerGroupPlan(containers: [
            container("a", .removing), container("b", .unknown),
        ])
        #expect(!plan.canStart)
        #expect(!plan.canStop)
    }
}

@Suite struct DockerProbeClassificationTests {
    @Test func silenceMeansTheProbeNeverAnswered() {
        let availability = DockerParsing.availability(
            versionOutput: "", versionStderr: "", status: 1)
        #expect(availability.status == .unknown)
        #expect(availability.isInstalled)
    }

    @Test func onlyAMissingBinaryHidesTheTab() {
        let missing = DockerParsing.availability(
            versionOutput: "", versionStderr: "bash: docker: command not found", status: 127)
        #expect(missing.status == .missing)
        #expect(!missing.isInstalled)
    }

    @Test func anInstalledButUnreachableDockerKeepsTheTab() {
        let down = DockerParsing.availability(
            versionOutput: "",
            versionStderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock.",
            status: 1)
        #expect(down.isInstalled)
        let denied = DockerParsing.availability(
            versionOutput: "", versionStderr: "permission denied while trying to connect",
            status: 1)
        #expect(denied.isInstalled)
    }
}

@Suite struct PowerOutcomeTests {
    private func failure(_ text: String, status: Int32 = 1) -> Error {
        SSHConnectionError.commandFailed(command: "reboot", status: status, stderr: text)
    }

    @Test func aMachineThatRefusesTheRequestIsNotReportedAsRestarting() {
        let denied = failure(
            "Failed to reboot: Interactive authentication required.")
        #expect(!PowerOutcome.hostWentAway(denied))
        #expect(PowerOutcome.explain(denied).contains("Interactive authentication required"))
        #expect(PowerOutcome.explain(denied).contains("Save this account's sudo password"))
    }

    @Test func theSudoPasswordPromptIsRecognisedAsAPrivilegeProblem() {
        #expect(PowerOutcome.needsPrivilege("sudo: a password is required"))
        #expect(PowerOutcome.needsPrivilege("Failed to reboot: Access denied"))
        #expect(!PowerOutcome.needsPrivilege("no such unit"))
    }

    @Test func aDroppedConnectionMeansTheRebootTookTheHostDown() {
        #expect(PowerOutcome.hostWentAway(failure("", status: 255)))
        #expect(PowerOutcome.hostWentAway(failure("Connection closed by remote host")))
        #expect(!PowerOutcome.hostWentAway(failure("Interactive authentication required.")))
    }

    @Test func theLastMeaningfulLineIsWhatTheUserSees() {
        let noisy = failure(
            "sudo: a password is required\nFailed to reboot: Interactive authentication required.")
        #expect(PowerOutcome.explain(noisy).hasPrefix("Failed to reboot:"))
    }

    @Test func anEmptyRefusalStillSaysSomething() {
        #expect(!PowerOutcome.explain(failure("")).isEmpty)
    }
}

@Suite struct ProcessCommandsTests {
    @Test func signalNamesAreAcceptedWithOrWithoutTheSIGPrefix() {
        #expect(ProcessCommands.normalizedSignal("term") == "TERM")
        #expect(ProcessCommands.normalizedSignal("SIGKILL") == "KILL")
        #expect(ProcessCommands.normalizedSignal("Hup") == "HUP")
    }

    @Test func anInventedSignalIsRefusedRatherThanSentBlindly() {
        #expect(ProcessCommands.normalizedSignal("NOPE") == nil)
        #expect(ProcessCommands.normalizedSignal("") == nil)
        #expect(ProcessCommands.normalizedSignal("9") == nil)
    }

    @Test func theKillLineChecksTheProcessIsStillThereBeforeSignallingIt() {
        let command = ProcessCommands.kill(pid: 42, signal: "TERM")
        #expect(command.contains("kill -0 42 2>/dev/null"))
        #expect(command.contains("kill -TERM 42 2>&1"))
        #expect(command.contains("echo \(ProcessCommands.goneMarker)"))
    }

    @Test func aProcessThatExitedBeforeTheSignalLandedIsToldApartFromAFailure() {
        #expect(ProcessCommands.hadAlreadyExited(ProcessCommands.goneMarker))
        #expect(!ProcessCommands.hadAlreadyExited(""))
        #expect(
            !ProcessCommands.hadAlreadyExited(
                "bash: line 1: kill: (1) - Operation not permitted"))
    }
}
