import Foundation
import Testing

@testable import EdithKit
@testable import EdithCLI

private final class PresentationCapture: @unchecked Sendable {
    var urls: [URL] = []
    var action: FilePresentationAction?
}

private final class RemoteDirectoryCapture: @unchecked Sendable {
    var listed: [String] = []
    var created: [String] = []
}

private enum RemoteOperationTestError: Error {
    case failed
}

private actor PreviewTransferGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@Suite struct RemoteFileOperationTests {
    @Test func descriptorsAreUniqueAndPointAtLeafCommands() {
        let descriptors =
            RemoteFileOperation.allCases.map(\.descriptor)
            + PortForwardBrowserOperation.allCases.map(\.descriptor)
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
        #expect(RemoteFileOperation.preview.descriptor.effect == .read)
        #expect(RemoteFileOperation.download.descriptor.effect == .write)
        #expect(RemoteFileOperation.launch.descriptor.effect == .interactive)
    }

    @Test func previewUsesOneSentinelByteAndQuotesThePath() {
        let command = RemoteFileOperationExecution.previewCommand(
            path: "/tmp/a user's notes", limit: 20)
        #expect(command == "head -c 21 '/tmp/a user'\\''s notes'")
    }

    @Test func previewDecodingReportsTruncationWithoutLeakingTheSentinel() {
        let preview = RemoteFileOperationExecution.textPreview(Data("abcdef".utf8), limit: 5)
        #expect(preview.text == "abcde")
        #expect(preview.truncated)
        let complete = RemoteFileOperationExecution.textPreview(Data("abc".utf8), limit: 5)
        #expect(complete.text == "abc")
        #expect(!complete.truncated)
    }

    @Test func remotePreviewPolicyRequiresIntentBeforeLargeTransfers() {
        let small = RemoteFileEntry(
            name: "small.pdf", path: "/tmp/small.pdf", kind: .file,
            sizeBytes: RemoteFileOperationExecution.automaticPreviewLimitBytes)
        let large = RemoteFileEntry(
            name: "large.pdf", path: "/tmp/large.pdf", kind: .file,
            sizeBytes: RemoteFileOperationExecution.automaticPreviewLimitBytes + 1)
        let oversized = RemoteFileEntry(
            name: "oversized.pdf", path: "/tmp/oversized.pdf", kind: .file,
            sizeBytes: RemoteFileOperationExecution.cacheLimitBytes + 1)

        #expect(
            RemoteFileOperationExecution.automaticPreviewDecision(for: small, isLocal: false)
                == .automatic)
        #expect(
            RemoteFileOperationExecution.automaticPreviewDecision(for: large, isLocal: false)
                == .requiresExplicitDownload)
        #expect(
            RemoteFileOperationExecution.automaticPreviewDecision(for: oversized, isLocal: false)
                == .downloadOnly)
        #expect(
            RemoteFileOperationExecution.automaticPreviewDecision(for: oversized, isLocal: true)
                == .automatic)
    }

    @Test func materializationRejectsOversizedMetadataBeforeTransfer() async {
        let entry = RemoteFileEntry(
            name: "movie.mov", path: "/tmp/movie.mov", kind: .file, sizeBytes: 11)
        var transfers = 0

        await #expect(throws: RemoteFileOperationError.self) {
            try await RemoteFileOperationExecution.materialize(
                entry, machineID: UUID(), isLocal: false, maximumBytes: 10,
                cacheLimit: 10
            ) { _, _ in
                transfers += 1
            }
        }

        #expect(transfers == 0)
    }

    @Test func cachePathsAreStableAndIncludeFileIdentity() throws {
        let machineID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let first = RemoteFileEntry(
            name: "notes.txt", path: "/tmp/notes.txt", kind: .file, sizeBytes: 4,
            modified: Date(timeIntervalSince1970: 30))
        let second = RemoteFileEntry(
            name: "notes.txt", path: "/srv/notes.txt", kind: .file, sizeBytes: 4,
            modified: Date(timeIntervalSince1970: 30))
        let a = try RemoteFileOperationExecution.cacheURL(
            for: first, machineID: machineID, createDirectory: false)
        let b = try RemoteFileOperationExecution.cacheURL(
            for: first, machineID: machineID, createDirectory: false)
        let c = try RemoteFileOperationExecution.cacheURL(
            for: second, machineID: machineID, createDirectory: false)
        #expect(a == b)
        #expect(a != c)
        #expect(a.lastPathComponent == "notes.txt")
    }

    @Test func cachePathsRejectNamesThatEscapeTheirIdentityDirectory() throws {
        let machineID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        for name in ["../escape", "/tmp/escape", ".", ""] {
            let entry = RemoteFileEntry(
                name: name, path: "/tmp/value", kind: .file, sizeBytes: 4)
            #expect(throws: RemoteFileOperationError.self) {
                try RemoteFileOperationExecution.cacheURL(
                    for: entry, machineID: machineID, createDirectory: false)
            }
        }
    }

    @Test func materializationReusesTheSharedCache() async throws {
        let entry = RemoteFileEntry(
            name: "sample.txt", path: "/tmp/sample.txt", kind: .file, sizeBytes: 4,
            modified: Date(timeIntervalSince1970: 30))
        let machineID = UUID()
        let destination = try RemoteFileOperationExecution.cacheURL(
            for: entry, machineID: machineID)
        try? FileManager.default.removeItem(at: destination)
        var transfers = 0
        let first = try await RemoteFileOperationExecution.materialize(
            entry, machineID: machineID, isLocal: false
        ) { _, local in
            transfers += 1
            try Data("test".utf8).write(to: local)
        }
        let second = try await RemoteFileOperationExecution.materialize(
            entry, machineID: machineID, isLocal: false
        ) { _, _ in
            transfers += 1
        }
        #expect(first == second)
        #expect(transfers == 1)
        try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
    }

    @Test func materializationRefreshesAnIncompleteIdentity() async throws {
        let entry = RemoteFileEntry(
            name: "sample.txt", path: "/tmp/sample.txt", kind: .file, sizeBytes: 4)
        let machineID = UUID()
        let destination = try RemoteFileOperationExecution.cacheURL(
            for: entry, machineID: machineID)
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        try Data("old!".utf8).write(to: destination)
        var transfers = 0

        let materialized = try await RemoteFileOperationExecution.materialize(
            entry, machineID: machineID, isLocal: false
        ) { _, local in
            transfers += 1
            try Data("new!".utf8).write(to: local)
        }

        #expect(materialized == destination)
        #expect(transfers == 1)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new!")
    }

    @Test func downloadReplacesAnExistingFileWithoutLeavingTrailingBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-single-get-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("notes.txt")
        try Data("old trailing bytes".utf8).write(to: destination)

        try await RemoteFileOperationExecution.download(
            remotePath: "/remote/notes.txt", to: destination
        ) { path, staging in
            #expect(path == "/remote/notes.txt")
            #expect(staging != destination)
            try Data("new".utf8).write(to: staging)
        }

        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["notes.txt"])
    }

    @Test func failedDownloadPreservesTheExistingFileAndCleansItsStagingFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-single-get-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("notes.txt")
        let original = Data("keep this".utf8)
        try original.write(to: destination)

        await #expect(throws: RemoteOperationTestError.self) {
            try await RemoteFileOperationExecution.download(
                remotePath: "/remote/notes.txt", to: destination
            ) { _, staging in
                try Data("partial".utf8).write(to: staging)
                throw RemoteOperationTestError.failed
            }
        }

        #expect(try Data(contentsOf: destination) == original)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["notes.txt"])
    }

    @Test func materializationEvictsOldEntriesBeforePublishingWithinBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-preview-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var oldFolder = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 6).write(to: oldFolder.appendingPathComponent("old.bin"))
        var oldValues = URLResourceValues()
        oldValues.contentAccessDate = Date(timeIntervalSince1970: 1)
        try oldFolder.setResourceValues(oldValues)
        let entry = RemoteFileEntry(
            name: "fresh.bin", path: "/remote/fresh.bin", kind: .file, sizeBytes: 6,
            modified: Date(timeIntervalSince1970: 2))

        let destination = try await RemoteFileOperationExecution.materialize(
            entry, machineID: UUID(), isLocal: false, maximumBytes: 10,
            cacheLimit: 10, cacheRoot: root
        ) { _, staging in
            try Data(repeating: 2, count: 6).write(to: staging)
        }

        #expect(!FileManager.default.fileExists(atPath: oldFolder.path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: destination).count == 6)
    }

    @Test func materializationRemovesAnUnexpectedlyOversizedTransfer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-preview-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = RemoteFileEntry(
            name: "lying.bin", path: "/remote/lying.bin", kind: .file, sizeBytes: 4,
            modified: Date(timeIntervalSince1970: 2))
        let machineID = UUID()
        let destination = try RemoteFileOperationExecution.cacheURL(
            for: entry, machineID: machineID, createDirectory: false, root: root)

        await #expect(throws: RemoteFileOperationError.self) {
            try await RemoteFileOperationExecution.materialize(
                entry, machineID: machineID, isLocal: false, maximumBytes: 10,
                cacheLimit: 10, cacheRoot: root
            ) { _, staging in
                try Data(repeating: 3, count: 11).write(to: staging)
            }
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func concurrentReservationsCannotOvercommitTheCacheBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-preview-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = RemoteFileEntry(
            name: "first.bin", path: "/remote/first.bin", kind: .file, sizeBytes: 7,
            modified: Date(timeIntervalSince1970: 1))
        let second = RemoteFileEntry(
            name: "second.bin", path: "/remote/second.bin", kind: .file, sizeBytes: 7,
            modified: Date(timeIntervalSince1970: 1))
        let gate = PreviewTransferGate()
        let firstTransfer = Task {
            try await RemoteFileOperationExecution.materialize(
                first, machineID: UUID(), isLocal: false, maximumBytes: 10,
                cacheLimit: 10, cacheRoot: root
            ) { _, staging in
                await gate.pause()
                try Data(repeating: 1, count: 7).write(to: staging)
            }
        }
        await gate.waitUntilStarted()

        await #expect(throws: RemoteFileOperationError.self) {
            try await RemoteFileOperationExecution.materialize(
                second, machineID: UUID(), isLocal: false, maximumBytes: 10,
                cacheLimit: 10, cacheRoot: root
            ) { _, _ in
                Issue.record("The overcommitted transfer started")
            }
        }

        await gate.release()
        _ = try await firstTransfer.value
    }

    @Test func forwardedURLUsesTheLocalPort() {
        let forward = PortForward(machineID: UUID(), localPort: 8080, remotePort: 80)
        #expect(
            PortForwardBrowserOperationExecution.url(forward: forward)?.absoluteString
                == "http://localhost:8080")
    }

    @Test func dockerBrowserPortsCanBeDisambiguatedByEitherSide() {
        let container = DockerContainer(
            id: "abc", names: ["api"], image: "api", command: "", state: .running,
            status: "Up",
            ports: [
                DockerPortMapping(
                    hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80, proto: "tcp"),
                DockerPortMapping(hostIP: nil, hostPort: nil, containerPort: 9000, proto: "tcp"),
            ])
        #expect(
            LocalBrowserOperationExecution.publishedPorts(in: container, matching: 80)
                .map(\.hostPort) == [8080])
        #expect(
            LocalBrowserOperationExecution.publishedPorts(in: container, matching: 8080)
                .map(\.containerPort) == [80])
        #expect(
            LocalBrowserOperationExecution.publishedPorts(in: container, matching: nil).count == 1)
    }

    @Test func sharedPresentationPassesTheActionAndURLsThrough() {
        let capture = PresentationCapture()
        let url = URL(string: "http://localhost:8080")!
        let opened = RemoteFileOperationExecution.present([url], action: .open) { urls, action in
            capture.urls = urls
            capture.action = action
            return true
        }
        #expect(opened)
        #expect(capture.urls == [url])
        #expect(capture.action == .open)
    }
}

@Suite struct RemoteDirectoryOperationTests {
    @Test func descriptorsAreStableAndClassified() {
        let descriptors = RemoteDirectoryOperation.allCases.map(\.descriptor)
        #expect(
            descriptors.map(\.cli) == [
                ["machines", "files", "ls"], ["machines", "files", "mkdir"],
            ])
        #expect(descriptors.map(\.effect) == [.read, .write])
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
    }

    @Test func sharedExecutionResolvesHomeFiltersHiddenEntriesAndCreatesExactPath() async throws {
        let capture = RemoteDirectoryCapture()
        let endpoint = RemoteDirectoryEndpoint(
            machineName: "Box", home: { "/home/dev" },
            list: { path in
                capture.listed.append(path)
                return [
                    RemoteFileEntry(
                        name: ".secret", path: "\(path)/.secret", kind: .file,
                        sizeBytes: 2),
                    RemoteFileEntry(
                        name: "work", path: "\(path)/work", kind: .directory,
                        sizeBytes: 0),
                ]
            },
            create: { capture.created.append($0) })

        let listing = try await RemoteDirectoryOperationExecution.list(
            path: ".", showHidden: false, using: endpoint)
        let creation = try await RemoteDirectoryOperationExecution.create(
            path: "/home/dev/new", using: endpoint)

        #expect(listing.machineName == "Box")
        #expect(listing.path == "/home/dev")
        #expect(listing.entries.map(\.name) == ["work"])
        #expect(capture.listed == ["/home/dev"])
        #expect(creation == RemoteDirectoryCreation(machineName: "Box", path: "/home/dev/new"))
        #expect(capture.created == ["/home/dev/new"])
    }

    @Test func homeResolutionFailsClosedInsteadOfListingTheRemoteRoot() async {
        let endpoint = RemoteDirectoryEndpoint(
            machineName: "Box", home: { "" }, list: { _ in [] }, create: { _ in })

        await #expect(throws: RemoteDirectoryOperationError.invalidHomeDirectory) {
            try await RemoteDirectoryOperationExecution.list(
                path: ".", showHidden: false, using: endpoint)
        }
    }

    @Test func failedListingsNeverReturnPartialParsedOutput() throws {
        let output = "f\u{1F}4\u{1F}30\u{1F}644\u{1F}notes.txt\u{1F}\n"
        let result = SSHExecResult(
            status: 1, stdout: Data(output.utf8), stderr: Data("permission denied".utf8))

        #expect(throws: SSHConnectionError.self) {
            try RemoteDirectoryEndpoint.decodedListing(result, path: "/srv")
        }
    }
}

@Suite struct HerdrOperationTests {
    @Test func descriptorsCoverCommandAndAttach() {
        let descriptors = HerdrOperation.allCases.map(\.descriptor)
        #expect(descriptors.map(\.cli) == [["herdr", "command"], ["herdr", "attach"]])
        #expect(HerdrOperation.attach.descriptor.effect == .interactive)
        #expect(HerdrSessionOperation.list.descriptor.cli == ["herdr", "ls"])
    }

    @Test func localAttachUsesTheSameArgumentsAsThePrintedCommand() {
        let agent = Self.agent(local: true)
        let request = HerdrOperationExecution.localAttachRequest(
            for: agent, environment: ["TERM=xterm"],
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/herdr"))
        #expect(request.executable == "/opt/homebrew/bin/herdr")
        #expect(request.arguments == ["--session", "work", "agent", "attach", "w3:p1N"])
        #expect(request.environment == ["TERM=xterm"])
    }

    @Test func missingLocalToolFallsBackToTheSharedShellLine() {
        let request = HerdrOperationExecution.localAttachRequest(
            for: Self.agent(local: true), environment: [], executable: nil)
        #expect(request.executable == "/bin/zsh")
        #expect(
            request.arguments == [
                "-c", HerdrAttachCommand.remoteShellLine(session: "work", pane: "w3:p1N"),
            ])
    }

    @Test func remoteAttachUsesTheConnectionTransportAndSharedShellLine() {
        let machine = Machine(name: "Box", host: "box.example", port: 2222, username: "dev")
        let connection = SSHConnection(machine: machine)
        let request = HerdrOperationExecution.remoteAttachRequest(
            for: Self.agent(local: false), connection: connection,
            environment: ["TERM=xterm"])
        #expect(request.executable == SSHConnection.executable.path)
        #expect(
            request.arguments.last
                == HerdrAttachCommand.remoteShellLine(session: "work", pane: "w3:p1N"))
        #expect(request.arguments.contains("dev@box.example"))
        #expect(request.environment.first == "TERM=xterm")
    }

    @Test func hostJSONReportsReachabilitySeparatelyFromToolPresence() {
        let host = HerdrHostSnapshot(
            id: UUID().uuidString, name: "Offline", isLocal: false,
            herdrPresent: false, reachable: false, error: "connection timed out")
        let json = JSONSerializer.string(HerdrCLI.hostJSON(host), pretty: false)

        #expect(json.contains(#""herdr":false"#))
        #expect(json.contains(#""reachable":false"#))
        #expect(json.contains(#""error":"connection timed out""#))
    }

    static func agent(local: Bool) -> HerdrAgent {
        HerdrAgent.make(
            machineID: local ? HerdrHostSnapshot.localID : UUID().uuidString,
            machineName: local ? "This Mac" : "Box", machineIsLocal: local,
            sshTarget: local ? nil : "dev@box.example", session: "work", pane: "w3:p1N",
            kind: "agent", status: .working, title: "Test", workspace: "", cwd: "")
    }

    @Test func terminalLauncherRunsTheExactProcessEnvironment() async {
        await CLIProbe.inWorld { _ in
            let status = CLIEnvironment.launchTerminal(
                TerminalLaunchRequest(
                    executable: "/bin/zsh",
                    arguments: ["-c", "test \"$EDITH_REMOTE_OPERATION_TEST\" = ready"],
                    environment: ["EDITH_REMOTE_OPERATION_TEST=ready"]))
            #expect(status == 0)
        }
    }
}

@Suite struct CLIRemotePresentationTests {
    @Test func forwardOpenUsesTheSharedURLAndStableJSON() async {
        await CLIProbe.inWorld { _ in
            let machine = Machine(name: "Box", host: "box.example")
            MachineRegistry.add(machine)
            MachineRegistry.addForward(
                PortForward(machineID: machine.id, localPort: 8080, remotePort: 80))
            let capture = PresentationCapture()
            CLIEnvironment.presentURLs = { urls, action in
                capture.urls = urls
                capture.action = action
                return true
            }
            let result = await CLIProbe.capture([
                "machines", "forwards", "open", "box", "1", "--json",
            ])
            #expect(result.code == 0)
            #expect(result.object?["index"] as? Int == 1)
            #expect(result.object?["machine"] as? String == "Box")
            #expect(result.object?["opened"] as? Bool == true)
            #expect(result.object?["url"] as? String == "http://localhost:8080")
            #expect(capture.urls.map(\.absoluteString) == ["http://localhost:8080"])
            #expect(capture.action == .open)
        }
    }

    @Test func unknownForwardDoesNotOpenAnything() async {
        await CLIProbe.inWorld { _ in
            let machine = Machine(name: "Box", host: "box.example")
            MachineRegistry.add(machine)
            let capture = PresentationCapture()
            CLIEnvironment.presentURLs = { urls, action in
                capture.urls = urls
                capture.action = action
                return true
            }
            let result = await CLIProbe.capture([
                "machines", "forwards", "open", "box", "1", "--json",
            ])
            #expect(result.code == ExitCodes.notFound)
            #expect(result.stdout.isEmpty)
            #expect(capture.urls.isEmpty)
        }
    }
}

@Suite struct CLIRemoteDirectoryTests {
    @Test func listKeepsItsPlainAndJSONContractsThroughSharedExecution() async {
        await CLIProbe.inWorld { _ in
            let machine = Machine(name: "Box", host: "box.example")
            let capture = RemoteDirectoryCapture()
            CLIEnvironment.remoteDirectoryTarget = { _ in
                CLIRemoteDirectoryTarget(
                    machine: machine,
                    endpoint: RemoteDirectoryEndpoint(
                        machineName: machine.name, home: { "/home/dev" },
                        list: { path in
                            capture.listed.append(path)
                            return [
                                RemoteFileEntry(
                                    name: "work", path: "\(path)/work", kind: .directory,
                                    sizeBytes: 0, mode: "755"),
                                RemoteFileEntry(
                                    name: ".secret", path: "\(path)/.secret", kind: .file,
                                    sizeBytes: 2, mode: "600"),
                            ]
                        }, create: { _ in }))
            }

            let plain = await CLIProbe.capture(["machines", "files", "ls", "box"])
            let json = await CLIProbe.capture([
                "machines", "files", "ls", "box", ".", "--all", "--json",
            ])

            #expect(plain.code == 0)
            #expect(plain.stdout.contains("work"))
            #expect(!plain.stdout.contains(".secret"))
            #expect(json.code == 0)
            #expect(json.object?["path"] as? String == "/home/dev")
            #expect((json.object?["entries"] as? [[String: Any]])?.count == 2)
            #expect(capture.listed == ["/home/dev", "/home/dev"])
        }
    }

    @Test func mkdirKeepsItsPlainAndJSONContractsThroughSharedExecution() async {
        await CLIProbe.inWorld { _ in
            let machine = Machine(name: "Box", host: "box.example")
            let capture = RemoteDirectoryCapture()
            CLIEnvironment.remoteDirectoryTarget = { _ in
                CLIRemoteDirectoryTarget(
                    machine: machine,
                    endpoint: RemoteDirectoryEndpoint(
                        machineName: machine.name, home: { "/home/dev" }, list: { _ in [] },
                        create: { capture.created.append($0) }))
            }

            let plain = await CLIProbe.capture([
                "machines", "files", "mkdir", "box", "/srv/new",
            ])
            let json = await CLIProbe.capture([
                "machines", "files", "mkdir", "box", "/srv/json", "--json",
            ])

            #expect(plain.code == 0)
            #expect(plain.stdout == "made /srv/new\n")
            #expect(json.code == 0)
            #expect(json.object?["done"] as? Bool == true)
            #expect(json.object?["machine"] as? String == "Box")
            #expect(json.object?["path"] as? String == "/srv/json")
            #expect(capture.created == ["/srv/new", "/srv/json"])
        }
    }
}

@Suite struct CLIRemoteDirectoryProcessTests {
    @Test func shippedDebugEntryExposesBothDirectoryLeavesOutsideARepository() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-remote-directory-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let list = try CLIProcessProbe.run(
            ["machines", "files", "ls", "--help"], currentDirectory: outside)
        let create = try CLIProcessProbe.run(
            ["machines", "files", "mkdir", "--help"], currentDirectory: outside)

        #expect(list.code == 0)
        #expect(list.stdout.contains("List a remote directory"))
        #expect(create.code == 0)
        #expect(create.stdout.contains("Make a directory on the machine"))
        #expect(list.stderr.isEmpty)
        #expect(create.stderr.isEmpty)
    }
}
