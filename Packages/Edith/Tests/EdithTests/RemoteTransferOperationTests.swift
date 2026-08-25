import Foundation
import Testing

@testable import EdithKit

@Suite struct RemoteTransferOperationTests {
    @Test func descriptorsRequirePreviewAndPointAtDistinctLeaves() {
        let descriptors = RemoteTransferOperation.allCases.map(\.descriptor)
        #expect(
            descriptors.map(\.cli) == [
                ["machines", "files", "get-many"],
                ["machines", "files", "transfer"],
            ])
        #expect(descriptors.map(\.requiresPreview) == [true, true])
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
    }

    @Test func plansPreserveOrderAndAllocateKeepBothNames() {
        let existing = [entry("report.txt"), entry("report 2.txt")]
        let plan = RemoteTransferOperationExecution.plan(
            paths: ["/one/report.txt", "/two/notes.txt", "/three/report.txt"],
            destination: "/out", existing: existing)

        #expect(
            plan.items.map(\.sourcePath) == [
                "/one/report.txt", "/two/notes.txt", "/three/report.txt",
            ])
        #expect(
            plan.items.map(\.destinationPath) == [
                "/out/report 3.txt", "/out/notes.txt", "/out/report 4.txt",
            ])
        #expect(plan.replacements.isEmpty)
    }

    @Test func plansMakeReplacementAndSkipEffectsExplicit() {
        let plan = RemoteTransferOperationExecution.plan(
            paths: ["/one/a.txt", "/one/b.txt", "/one/c.txt"], destination: "/out",
            existing: [entry("a.txt"), entry("b.txt")],
            resolutions: ["a.txt": .replace, "b.txt": .skip])

        #expect(plan.items.map(\.destinationPath) == ["/out/a.txt", "/out/c.txt"])
        #expect(plan.replacements.map(\.destinationPath) == ["/out/a.txt"])
        #expect(plan.skipped == ["/one/b.txt"])
    }

    @Test func duplicateReplacementNamesResolveToDistinctDestinations() {
        let plan = RemoteTransferOperationExecution.plan(
            paths: ["/one/report.txt", "/two/report.txt"], destination: "/out",
            existing: [entry("report.txt")], resolution: .replace)

        #expect(plan.items.map(\.destinationPath) == ["/out/report.txt", "/out/report 2.txt"])
        #expect(plan.replacements.map(\.destinationPath) == ["/out/report.txt"])
    }

    @Test func largeDuplicateBatchesAllocateMonotonicSuffixes() {
        let paths = (0..<1_000).map { "/source-\($0)/report.txt" }
        let plan = RemoteTransferOperationExecution.plan(
            paths: paths, destination: "/out", existing: [entry("report.txt")])

        #expect(
            plan.items.map(\.destinationPath)
                == (2...1_001).map { "/out/report \($0).txt" })
    }

    @Test func replacementCannotExecuteWithoutConfirmation() async {
        let plan = RemoteTransferOperationExecution.plan(
            paths: ["/in/a.txt"], destination: "/out", existing: [entry("a.txt")],
            resolution: .replace)

        await #expect(throws: RemoteTransferError.self) {
            try await RemoteTransferOperationExecution.execute(
                plan, from: inertEndpoint(), to: inertEndpoint(),
                confirmsReplacement: false)
        }
    }

    @Test func localExecutionKeepsExistingFilesAndPublishesAsyncProgress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-transfer-local-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = source.appendingPathComponent("report.txt")
        let second = source.appendingPathComponent("notes.txt")
        try Data("new".utf8).write(to: first)
        try Data("notes".utf8).write(to: second)
        try Data("old".utf8).write(to: destination.appendingPathComponent("report.txt"))
        let sourceEndpoint = RemoteTransferEndpoint.local(machineID: UUID(), name: "Source")
        let destinationEndpoint = RemoteTransferEndpoint.local(
            machineID: UUID(), name: "Destination")
        let existing = try await destinationEndpoint.list(destination.path)
        let plan = RemoteTransferOperationExecution.plan(
            paths: [first.path, second.path], destination: destination.path,
            existing: existing)
        let progress = TransferProgressRecorder()

        let outcome = try await RemoteTransferOperationExecution.execute(
            plan, from: sourceEndpoint, to: destinationEndpoint,
            confirmsReplacement: false
        ) { processed, total in
            await progress.record(processed: processed, total: total)
        }

        #expect(outcome.failures.isEmpty)
        #expect(
            outcome.completed.map(\.destinationPath) == [
                destination.appendingPathComponent("report 2.txt").path,
                destination.appendingPathComponent("notes.txt").path,
            ])
        #expect(await progress.values() == [[1, 2], [2, 2]])
        #expect(
            try String(
                contentsOf: destination.appendingPathComponent("report.txt"),
                encoding: .utf8) == "old")
        #expect(
            try String(
                contentsOf: destination.appendingPathComponent("report 2.txt"),
                encoding: .utf8) == "new")
    }

    @Test func failuresReportResolvedDestinationsAndProcessedProgress() async throws {
        let progress = TransferProgressRecorder()
        let destination = RemoteTransferEndpoint(
            machineID: UUID(), name: "Destination", list: { _ in [] },
            fetch: { _, _ in }, store: { _, _, _ in })
        let source = RemoteTransferEndpoint(
            machineID: UUID(), name: "Source", list: { _ in [] },
            fetch: { path, url in
                if path.hasSuffix("bad.txt") {
                    throw RemoteTransferError.listingFailed("unreadable")
                }
                try Data(path.utf8).write(to: url)
            }, store: { _, _, _ in })
        let plan = RemoteTransferOperationExecution.plan(
            paths: ["/a.txt", "/bad.txt", "/c.txt"], destination: "/out", existing: [])

        let outcome = try await RemoteTransferOperationExecution.execute(
            plan, from: source, to: destination, confirmsReplacement: false
        ) { processed, total in
            await progress.record(processed: processed, total: total)
        }

        #expect(outcome.completed.map(\.sourcePath) == ["/a.txt", "/c.txt"])
        #expect(outcome.failures.map(\.sourcePath) == ["/bad.txt"])
        #expect(outcome.failures.first?.destination == "/out/bad.txt")
        #expect(outcome.failures.first?.message == "unreadable")
        #expect(await progress.values() == [[1, 3], [2, 3], [3, 3]])
    }

    @Test func callerStagingRootSurvivesAndExecutorChildrenAreRemoved() async throws {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-transfer-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: stagingRoot, withIntermediateDirectories: true)
        let sentinel = stagingRoot.appendingPathComponent("sentinel")
        try Data().write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let source = RemoteTransferEndpoint(
            machineID: UUID(), name: "Source", list: { _ in [] },
            fetch: { path, url in
                try Data(path.utf8).write(to: url)
                if path.hasSuffix("bad.txt") {
                    throw RemoteTransferError.listingFailed("stopped")
                }
            }, store: { _, _, _ in })
        let plan = RemoteTransferOperationExecution.plan(
            paths: ["/bad.txt", "/good.txt"], destination: "/out", existing: [])

        let outcome = try await RemoteTransferOperationExecution.execute(
            plan, from: source, to: inertEndpoint(), confirmsReplacement: false,
            stagingRoot: stagingRoot)

        #expect(outcome.completed.map(\.sourcePath) == ["/good.txt"])
        #expect(outcome.failures.map(\.sourcePath) == ["/bad.txt"])
        #expect(FileManager.default.fileExists(atPath: stagingRoot.path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
                == ["sentinel"])
    }

    @Test func eachItemStagingDirectoryIsRemovedBeforeTheNextFetch() async throws {
        let source = RemoteTransferEndpoint(
            machineID: UUID(), name: "Source", list: { _ in [] },
            fetch: { path, url in
                if path == "/second.txt" {
                    let previous = url.deletingLastPathComponent()
                        .deletingLastPathComponent().appendingPathComponent("0")
                    if FileManager.default.fileExists(atPath: previous.path) {
                        throw TransferTestError.staleItemStaging
                    }
                }
                try Data(path.utf8).write(to: url)
            }, store: { _, _, _ in })
        let plan = RemoteTransferOperationExecution.plan(
            paths: ["/first.txt", "/second.txt"], destination: "/out", existing: [])

        let outcome = try await RemoteTransferOperationExecution.execute(
            plan, from: source, to: inertEndpoint(), confirmsReplacement: false)

        #expect(outcome.completed.map(\.sourcePath) == ["/first.txt", "/second.txt"])
        #expect(outcome.failures.isEmpty)
    }

    @Test func cancellationStopsBeforeLaterItemsAndPreservesCallerStagingRoot() async throws {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-transfer-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let calls = TransferCallCounter()
        let source = RemoteTransferEndpoint(
            machineID: UUID(), name: "Source", list: { _ in [] },
            fetch: { path, _ in
                calls.record(path)
                throw CancellationError()
            }, store: { _, _, _ in })
        let plan = RemoteTransferOperationExecution.plan(
            paths: ["/a.txt", "/b.txt"], destination: "/out", existing: [])

        await #expect(throws: CancellationError.self) {
            try await RemoteTransferOperationExecution.execute(
                plan, from: source, to: inertEndpoint(), confirmsReplacement: false,
                stagingRoot: stagingRoot)
        }

        #expect(calls.values() == ["/a.txt"])
        #expect(FileManager.default.fileExists(atPath: stagingRoot.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path).isEmpty)
    }

    @Test func genericErrorsFromACancelledTransferPropagateAsCancellation() async {
        let calls = TransferCallCounter()
        let source = RemoteTransferEndpoint(
            machineID: UUID(), name: "Source", list: { _ in [] },
            fetch: { path, _ in
                calls.record(path)
                withUnsafeCurrentTask { $0?.cancel() }
                throw TransferTestError.failedAfterCancellation
            }, store: { _, _, _ in })
        let plan = RemoteTransferOperationExecution.plan(
            paths: ["/a.txt", "/b.txt"], destination: "/out", existing: [])
        let execution = Task {
            try await RemoteTransferOperationExecution.execute(
                plan, from: source, to: inertEndpoint(), confirmsReplacement: false)
        }

        await #expect(throws: CancellationError.self) {
            try await execution.value
        }
        #expect(calls.values() == ["/a.txt"])
    }

    @Test func cancellationAfterStoreCannotReturnASuccessfulOutcome() async {
        let source = RemoteTransferEndpoint(
            machineID: UUID(), name: "Source", list: { _ in [] },
            fetch: { path, url in try Data(path.utf8).write(to: url) },
            store: { _, _, _ in withUnsafeCurrentTask { $0?.cancel() } })
        let plan = RemoteTransferOperationExecution.plan(
            paths: ["/a.txt"], destination: "/out", existing: [])
        let execution = Task {
            try await RemoteTransferOperationExecution.execute(
                plan, from: source, to: source, confirmsReplacement: false)
        }

        await #expect(throws: CancellationError.self) {
            try await execution.value
        }
    }

    @Test func cancellationFromProgressCannotReturnASuccessfulOutcome() async {
        let source = RemoteTransferEndpoint(
            machineID: UUID(), name: "Source", list: { _ in [] },
            fetch: { path, url in try Data(path.utf8).write(to: url) },
            store: { _, _, _ in })
        let plan = RemoteTransferOperationExecution.plan(
            paths: ["/a.txt"], destination: "/out", existing: [])
        let execution = Task {
            try await RemoteTransferOperationExecution.execute(
                plan, from: source, to: source, confirmsReplacement: false
            ) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        await #expect(throws: CancellationError.self) {
            try await execution.value
        }
    }

    @Test func localListingFailureDoesNotBecomeAnEmptyDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-transfer-missing-\(UUID().uuidString)")
        let endpoint = RemoteTransferEndpoint.local(machineID: UUID(), name: "Local")

        await #expect(throws: Error.self) {
            try await endpoint.list(root.path)
        }
    }

    @Test func failedLocalReplacementPreservesTheExistingDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-transfer-replacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("report.txt")
        try Data("old".utf8).write(to: destination)
        let source = RemoteTransferEndpoint(
            machineID: UUID(), name: "Source", list: { _ in [] },
            fetch: { _, _ in }, store: { _, _, _ in })
        let target = RemoteTransferEndpoint.local(machineID: UUID(), name: "Target")
        let plan = RemoteTransferOperationExecution.plan(
            paths: ["/missing/report.txt"], destination: root.path,
            existing: [entry("report.txt")], resolution: .replace)

        let outcome = try await RemoteTransferOperationExecution.execute(
            plan, from: source, to: target, confirmsReplacement: true)

        #expect(outcome.completed.isEmpty)
        #expect(outcome.failures.first?.destination == destination.path)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "old")
    }

    @Test func remoteKeepBothPublicationCannotOverwriteAConcurrentDestination() {
        let command = RemoteTransferEndpoint.remoteStoreCommand(
            staged: "/out/.report.edith-stage", target: "/out/report", replacing: false)

        #expect(command.contains("mv -n /out/.report.edith-stage /out/report"))
        #expect(command.contains("edith_status"))
        #expect(
            command.contains(
                "[ -e /out/.report.edith-stage ] || [ -L /out/.report.edith-stage ]"))
        #expect(command.contains("edith_source_inode"))
        #expect(command.contains("edith_target_inode"))
        #expect(command.contains("The destination changed before publication."))
        #expect(!command.contains("ln "))
    }

    @Test func remoteReplacementUsesARollbackPathUntilPublication() throws {
        let command = RemoteTransferEndpoint.remoteStoreCommand(
            staged: "/out/.report.edith-stage", target: "/out/report", replacing: true)
        let backupPrefix = "/out/report\(NameConflicts.stagingSuffix)-backup-"
        let backupStart = try #require(command.range(of: backupPrefix))
        let backup = String(
            command[backupStart.lowerBound...].prefix {
                !$0.isWhitespace && $0 != ";"
            })
        let preserve = try #require(command.range(of: "mv /out/report \(backup)"))
        let publish = try #require(
            command.range(of: "mv -n /out/.report.edith-stage /out/report"))
        let rollback = try #require(
            command.range(
                of: "mv -n \(backup) /out/report",
                range: publish.upperBound..<command.endIndex))
        let cleanup = try #require(command.range(of: "rm -f \(backup)"))

        #expect(command.contains("[ -d /out/report ] && [ ! -L /out/report ]"))
        #expect(command.contains("[ -e /out/report ] || [ -L /out/report ]"))
        #expect(command.contains("edith_status"))
        #expect(command.contains("edith_source_inode"))
        #expect(command.contains("edith_target_inode"))
        #expect(preserve.lowerBound < publish.lowerBound)
        #expect(publish.lowerBound < cleanup.lowerBound)
        #expect(publish.lowerBound < rollback.lowerBound)
        #expect(command.contains("mv -n /out/.report.edith-stage /out/report"))
        #expect(
            command.contains(
                "[ -e /out/.report.edith-stage ] || [ -L /out/.report.edith-stage ]"))
        #expect(!command.contains("mv -f /out/.report.edith-stage /out/report"))
    }

    @Test func remoteReplacementDirectoryRaceRetainsTheOriginalBackup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-remote-replace-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent(".report.stage")
        let target = root.appendingPathComponent("report.txt")
        try Data("new".utf8).write(to: staged)
        try Data("old".utf8).write(to: target)
        let publication = RemoteTransferEndpoint.remoteStoreCommand(
            staged: staged.path, target: target.path, replacing: true)
        let source = ShellQuote.quote(staged.path)
        let destination = ShellQuote.quote(target.path)
        let command =
            "function mv { if [ \"$1\" = -n ] && [ \"$2\" = \(source) ]"
            + " && [ \"$3\" = \(destination) ]; then mkdir \(destination); fi;"
            + " command mv \"$@\"; }; \(publication)"

        let result = await LocalMachineCommandExecution.run(command)

        #expect(throws: Error.self) { try result.get() }
        var targetIsDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: target.path, isDirectory: &targetIsDirectory))
        #expect(targetIsDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let backupName = try #require(
            names.first {
                $0.hasPrefix("report.txt\(NameConflicts.stagingSuffix)-backup-")
            })
        #expect(
            try String(
                contentsOf: root.appendingPathComponent(backupName), encoding: .utf8) == "old")
    }

    private func entry(_ name: String) -> RemoteFileEntry {
        RemoteFileEntry(name: name, path: "/out/\(name)", kind: .file, sizeBytes: 1)
    }

    private func inertEndpoint() -> RemoteTransferEndpoint {
        RemoteTransferEndpoint(
            machineID: UUID(), name: "Test", list: { _ in [] }, fetch: { _, _ in },
            store: { _, _, _ in })
    }
}

private enum TransferTestError: Error {
    case failedAfterCancellation
    case staleItemStaging
}

private actor TransferProgressRecorder {
    private var updates: [[Int]] = []

    func record(processed: Int, total: Int) {
        updates.append([processed, total])
    }

    func values() -> [[Int]] {
        updates
    }
}

private final class TransferCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ value: String) {
        lock.withLock { recorded.append(value) }
    }

    func values() -> [String] {
        lock.withLock { recorded }
    }
}
