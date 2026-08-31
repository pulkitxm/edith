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
                ["machines", "files", "put"],
                ["machines", "files", "cp"],
                ["machines", "files", "mv"],
            ])
        #expect(descriptors.map(\.requiresPreview) == [true, true, true, true, true])
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

    @Test func exactDestinationPlansMakeEveryResolutionExplicit() {
        let existing = [entry("report.txt"), entry("report 2.txt")]
        let kept = RemoteTransferOperationExecution.plan(
            sourcePath: "/in/source.txt", destinationPath: "/out/report.txt",
            existing: existing)
        let replaced = RemoteTransferOperationExecution.plan(
            sourcePath: "/in/source.txt", destinationPath: "/out/report.txt",
            existing: existing, resolution: .replace)
        let skipped = RemoteTransferOperationExecution.plan(
            sourcePath: "/in/source.txt", destinationPath: "/out/report.txt",
            existing: existing, resolution: .skip)

        #expect(kept.items.map(\.destinationPath) == ["/out/report 3.txt"])
        #expect(!kept.items[0].replacesExisting)
        #expect(replaced.items.map(\.destinationPath) == ["/out/report.txt"])
        #expect(replaced.items[0].replacesExisting)
        #expect(skipped.items.isEmpty)
        #expect(skipped.skipped == ["/in/source.txt"])
    }

    @Test func windowsPlansPreserveRemoteNamesAndSeparators() {
        let plan = RemoteTransferOperationExecution.plan(
            paths: ["C:\\Users\\Pulkit\\report.txt"], destination: "~\\Desktop\\out",
            existing: [])
        let exact = RemoteTransferOperationExecution.plan(
            sourcePath: "/tmp/report.txt",
            destinationPath: "~\\Desktop\\out\\renamed.txt", existing: [])

        #expect(plan.items.first?.destinationPath == "~\\Desktop\\out\\report.txt")
        #expect(exact.destination == "~\\Desktop\\out")
        #expect(exact.items.first?.destinationPath == "~\\Desktop\\out\\renamed.txt")
    }

    @Test func withinMachineCommandsRejectSelfAndDescendantDestinations() {
        let selfPlan = RemoteTransferPlan(
            destination: "/a",
            items: [
                RemoteTransferPlanItem(
                    sourcePath: "/a/report", destinationPath: "/a/report",
                    replacesExisting: true)
            ], skipped: [])
        let descendantPlan = RemoteTransferPlan(
            destination: "/a/report",
            items: [
                RemoteTransferPlanItem(
                    sourcePath: "/a/report", destinationPath: "/a/report/archive",
                    replacesExisting: false)
            ], skipped: [])

        #expect(
            RemoteTransferOperationExecution.withinMachineCommand(selfPlan, moving: true) == nil)
        #expect(
            RemoteTransferOperationExecution.withinMachineCommand(
                descendantPlan, moving: false) == nil)
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
            machineID: UUID(), name: "Destination", isDirectory: { _ in false },
            list: { _ in [] },
            fetch: { _, _ in }, store: { _, _, _ in })
        let source = RemoteTransferEndpoint(
            machineID: UUID(), name: "Source", isDirectory: { _ in false }, list: { _ in [] },
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
            machineID: UUID(), name: "Source", isDirectory: { _ in false }, list: { _ in [] },
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
            machineID: UUID(), name: "Source", isDirectory: { _ in false }, list: { _ in [] },
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
            machineID: UUID(), name: "Source", isDirectory: { _ in false }, list: { _ in [] },
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
            machineID: UUID(), name: "Source", isDirectory: { _ in false }, list: { _ in [] },
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
            machineID: UUID(), name: "Source", isDirectory: { _ in false }, list: { _ in [] },
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
            machineID: UUID(), name: "Source", isDirectory: { _ in false }, list: { _ in [] },
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

    @Test func localEndpointProbesDirectoriesWithoutListingTheirContents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-transfer-probe-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("folder")
        let file = root.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = RemoteTransferEndpoint.local(machineID: UUID(), name: "Local")

        #expect(try await endpoint.isDirectory(directory.path))
        #expect(try await !endpoint.isDirectory(file.path))
        #expect(try await !endpoint.isDirectory(root.appendingPathComponent("missing").path))
    }

    @Test func failedLocalReplacementPreservesTheExistingDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-transfer-replacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("report.txt")
        try Data("old".utf8).write(to: destination)
        let source = RemoteTransferEndpoint(
            machineID: UUID(), name: "Source", isDirectory: { _ in false }, list: { _ in [] },
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

    @Test func withinMachineDirectoryCopyReplacesTransactionally() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-within-copy-\(UUID().uuidString)")
        let sourceRoot = root.appendingPathComponent("source")
        let destinationRoot = root.appendingPathComponent("destination")
        let source = sourceRoot.appendingPathComponent("report")
        let destination = destinationRoot.appendingPathComponent("report")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("new.txt"))
        try Data("old".utf8).write(to: destination.appendingPathComponent("old.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = RemoteTransferOperationExecution.plan(
            sourcePath: source.path, destinationPath: destination.path,
            existing: [directoryEntry("report")], resolution: .replace)
        let command = try #require(
            RemoteTransferOperationExecution.withinMachineCommand(plan, moving: false))

        _ = try await LocalMachineCommandExecution.run(command).get()

        #expect(
            FileManager.default.fileExists(atPath: source.appendingPathComponent("new.txt").path))
        #expect(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("new.txt").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("old.txt").path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path) == ["report"])
    }

    @Test func localCommandExecutionPreservesExecutableArguments() async throws {
        let result = await LocalMachineCommandExecution.run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "edith argument with spaces"], commandLabel: "printf")

        #expect(try result.get() == "edith argument with spaces")
    }

    @Test func withinMachineDirectoryMoveDeletesSourceOnlyAfterPublication() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-within-move-\(UUID().uuidString)")
        let sourceRoot = root.appendingPathComponent("source")
        let destinationRoot = root.appendingPathComponent("destination")
        let source = sourceRoot.appendingPathComponent("report")
        let destination = destinationRoot.appendingPathComponent("report")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destinationRoot, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("new.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = RemoteTransferOperationExecution.plan(
            sourcePath: source.path, destinationPath: destination.path, existing: [])
        let command = try #require(
            RemoteTransferOperationExecution.withinMachineCommand(plan, moving: true))

        _ = try await LocalMachineCommandExecution.run(command).get()

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("new.txt").path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path) == ["report"])
    }

    @Test func failedWithinMachinePublicationPreservesSourceAndOriginalDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-within-rollback-\(UUID().uuidString)")
        let sourceRoot = root.appendingPathComponent("source")
        let destinationRoot = root.appendingPathComponent("destination")
        let source = sourceRoot.appendingPathComponent("report")
        let destination = destinationRoot.appendingPathComponent("report")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("new.txt"))
        try Data("old".utf8).write(to: destination.appendingPathComponent("old.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = RemoteTransferOperationExecution.plan(
            sourcePath: source.path, destinationPath: destination.path,
            existing: [directoryEntry("report")], resolution: .replace)
        let operation = try #require(
            RemoteTransferOperationExecution.withinMachineCommand(plan, moving: true))
        let target = ShellQuote.quote(destination.path)
        let command =
            "function mv { if [ \"$1\" = -n ] && [ \"$3\" = \(target) ]; then "
            + "case \"$2\" in *\(NameConflicts.stagingSuffix)-backup-*) ;; *) return 91;; esac; "
            + "fi; command mv \"$@\"; }; \(operation)"

        let result = await LocalMachineCommandExecution.run(command)

        #expect(throws: Error.self) { try result.get() }
        #expect(
            FileManager.default.fileExists(atPath: source.appendingPathComponent("new.txt").path))
        #expect(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("old.txt").path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path) == ["report"])
    }

    @Test func concurrentDirectoryDestinationDoesNotCaptureTheStagedCopy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-within-race-\(UUID().uuidString)")
        let sourceRoot = root.appendingPathComponent("source")
        let destinationRoot = root.appendingPathComponent("destination")
        let source = sourceRoot.appendingPathComponent("report")
        let destination = destinationRoot.appendingPathComponent("report")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destinationRoot, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("new.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = RemoteTransferOperationExecution.plan(
            sourcePath: source.path, destinationPath: destination.path, existing: [])
        let operation = try #require(
            RemoteTransferOperationExecution.withinMachineCommand(plan, moving: false))
        let target = ShellQuote.quote(destination.path)
        let command =
            "function mv { if [ \"$1\" = -n ] && [ \"$3\" = \(target) ]; then "
            + "mkdir \(target); fi; command mv \"$@\"; }; \(operation)"

        let result = await LocalMachineCommandExecution.run(command)

        #expect(throws: Error.self) { try result.get() }
        #expect(
            FileManager.default.fileExists(atPath: source.appendingPathComponent("new.txt").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path) == ["report"])
    }

    @Test func withinMachineBatchStopsAfterTheFirstFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-within-batch-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let second = root.appendingPathComponent("second.txt")
        try Data("second".utf8).write(to: second)
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = RemoteTransferOperationExecution.plan(
            paths: [root.appendingPathComponent("missing.txt").path, second.path],
            destination: destination.path, existing: [])
        let command = try #require(
            RemoteTransferOperationExecution.withinMachineCommand(plan, moving: false))

        let result = await LocalMachineCommandExecution.run(command)

        #expect(throws: Error.self) { try result.get() }
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("second.txt").path))
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

    @Test func windowsUploadPublicationUsesNativeAtomicFileOperations() throws {
        let keep = RemoteTransferEndpoint.remoteStoreCommand(
            staged: "~\\out\\.report.edith-stage", target: "~\\out\\report.txt",
            replacing: false, platform: .windows)
        let replace = RemoteTransferEndpoint.remoteStoreCommand(
            staged: "~\\out\\.report.edith-stage", target: "~\\out\\report.txt",
            replacing: true, platform: .windows)
        let keepScript = try #require(decodedPowerShell(keep))
        let replaceScript = try #require(decodedPowerShell(replace))

        #expect(keepScript.contains("[IO.File]::Move($source,$target)"))
        #expect(keepScript.contains("$replace=$false"))
        #expect(replaceScript.contains("[IO.File]::Replace($source,$target,$backup,$true)"))
        #expect(replaceScript.contains("$replace=$true"))
        #expect(replaceScript.contains("GetUnresolvedProviderPathFromPSPath"))
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

    private func directoryEntry(_ name: String) -> RemoteFileEntry {
        RemoteFileEntry(name: name, path: "/out/\(name)", kind: .directory, sizeBytes: 1)
    }

    private func inertEndpoint() -> RemoteTransferEndpoint {
        RemoteTransferEndpoint(
            machineID: UUID(), name: "Test", isDirectory: { _ in false }, list: { _ in [] },
            fetch: { _, _ in },
            store: { _, _, _ in })
    }

    private func decodedPowerShell(_ command: String) -> String? {
        guard let encoded = command.split(separator: " ").last,
            let data = Data(base64Encoded: String(encoded))
        else { return nil }
        return String(data: data, encoding: .utf16LittleEndian)
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
