import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIAppActionTests {
    @Test func everyActionIsReachableAsItsOwnSubcommand() throws {
        for action in AppActions.all {
            let parsed = try EdRoot.parseAsRoot(["app", action.name])
            #expect(CommandCrawler.name(of: type(of: parsed)) == action.name)
        }
    }

    @Test func theActionListNamesEveryActionTheCommandGroupHas() async {
        let result = await CLIProbe.run(["app", "actions", "--json"])
        #expect(result.code == 0)
        let rows = result.array as? [[String: Any]] ?? []
        #expect(rows.compactMap { $0["action"] as? String } == AppActions.all.map(\.name))
        for row in rows {
            #expect(Set(row.keys) == ["action", "summary", "needs", "available"])
            #expect(row["available"] as? Bool == false)
        }
    }

    @Test func anActionThatNeedsTheMenuBarSaysSoWhenItIsClosed() async {
        for name in ["clean-keys", "test-notification", "open"] {
            let result = await CLIProbe.run(["app", name])
            #expect(result.code == ExitCodes.unavailable, "\(name) exited \(result.code)")
            #expect(result.stderr.contains("menu bar app"))
            #expect(result.stdout.isEmpty)
        }
    }

    @Test func anActionThatNeedsTheMainWindowSaysSoWhenItIsClosed() async {
        for name in ["quit", "check-updates"] {
            let result = await CLIProbe.run(["app", name])
            #expect(result.code == ExitCodes.unavailable, "\(name) exited \(result.code)")
            #expect(result.stderr.contains("main window"))
        }
    }

    @Test func eachActionPostsItsOwnNotificationAndNoOther() async throws {
        let expected: [String: Notification.Name] = [
            "clean-keys": IPC.Name.requestKeyboardClean,
            "test-notification": IPC.Name.requestTestNotification,
            "open": IPC.Name.openPanel,
        ]
        for (name, notification) in expected {
            try await CLIProbe.inWorld { world in
                world.helperRunning(true)
                let result = await CLIProbe.capture(["app", name])
                #expect(result.code == 0, "\(name) exited \(result.code)")
                #expect(world.postedNames() == [notification.rawValue])
            }
        }
    }

    @Test func quitAsksTheMainAppRatherThanTheMenuBar() async throws {
        try await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            let result = await CLIProbe.capture(["app", "quit", "--json"])
            #expect(result.code == 0)
            #expect(world.postedNames() == [IPC.Name.quitMainApp.rawValue])
            #expect(result.object?["action"] as? String == "quit")
        }
    }

    @Test func anUpdateCheckWaitsForTheAppToFinishAndReportsTheOutcome() async throws {
        try await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in ["outcome": "updateFound", "version": "2.1.0"] }
            let result = await CLIProbe.capture(["app", "check-updates", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["outcome"] as? String == "updateFound")
            #expect(result.object?["version"] as? String == "2.1.0")
            #expect(result.object?["finished"] as? Bool == true)
            #expect(world.postedNames() == [IPC.Name.requestUpdateCheck.rawValue])
        }
    }

    @Test func anUpdateCheckThatGoesQuietIsDiagnosedRatherThanCallingItDone() async throws {
        try await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.helperRunning(true)
            world.answers { _ in nil }
            let result = await CLIProbe.capture(["app", "check-updates"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("did not answer"))
        }
    }

    @Test func noWaitReturnsWithoutClaimingTheCheckFinished() async throws {
        try await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in nil }
            let result = await CLIProbe.capture(["app", "check-updates", "--no-wait", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["finished"] as? Bool == false)
        }
    }

    @Test func theUpdateLogIsReadWithoutTheAppRunning() async {
        let result = await CLIProbe.run(["app", "updates", "--json"])
        #expect(result.code == 0)
        #expect(result.array != nil)
    }

    @Test func anUnknownActionIsNotFound() {
        #expect(throws: CLIFailure.self) { try AppActions.named("self-destruct") }
    }
}

@Suite struct CLIClipboardTests {
    static func seed(_ world: CLIWorld, count: Int) throws {
        var entries: [ClipboardEntry] = []
        for index in 0..<count {
            let text = "entry number \(index)"
            let data = Data(text.utf8)
            let sha = ClipboardRepository.sha256Hex(data)
            try ClipboardRepository.writeBlob(data, sha256: sha, ext: "txt")
            entries.append(
                ClipboardEntry(
                    sha256: sha, types: ["public.utf8-plain-text"], ext: "txt",
                    sourceApp: "Tester", sourceBundleID: "test.app",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    size: data.count, preview: text, pinned: index == 0))
        }
        try ClipboardRepository.saveEntries(entries)
    }

    @Test func anEmptyHistoryIsUnavailableRatherThanACrash() async {
        let result = await CLIProbe.run(["clipboard", "get", "1"])
        #expect(result.code == ExitCodes.unavailable)
        #expect(result.stderr.contains("empty"))
    }

    @Test func listingIsPinnedThenNewestFirstAndNumberedFromOne() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, count: 3)
            let result = await CLIProbe.capture(["clipboard", "ls", "--json"])
            #expect(result.code == 0)
            let rows = result.array as? [[String: Any]] ?? []
            #expect(rows.count == 3)
            #expect(rows.first?["index"] as? Int == 1)
            #expect(
                rows.map { $0["preview"] as? String } == [
                    "entry number 0", "entry number 2", "entry number 1",
                ])
        }
    }

    @Test func theCLIAndThePanelNumberTheSameEntries() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, count: 3)
            let result = await CLIProbe.capture(["clipboard", "ls", "--json"])
            let rows = result.array as? [[String: Any]] ?? []
            let panel = ClipboardActions.arrange(ClipboardRepository.loadEntries())
            #expect(rows.map { $0["id"] as? String } == panel.map(\.id))
        }
    }

    @Test func gettingAnEntryPrintsItsTextAndNothingElse() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, count: 2)
            let result = await CLIProbe.capture(["clipboard", "get", "2"])
            #expect(result.code == 0)
            #expect(result.stdout == "entry number 1\n")
        }
    }

    @Test func statsCountEveryEntryAndWhatItWeighs() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, count: 3)
            let result = await CLIProbe.capture(["clipboard", "stats", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["count"] as? Int == 3)
            #expect(result.object?["pinned"] as? Int == 1)
            let entries = ClipboardRepository.loadEntries()
            #expect(result.object?["sizeBytes"] as? Int == entries.reduce(0) { $0 + $1.size })
            #expect(result.object?["largestBytes"] as? Int == entries.map(\.size).max())
            let kinds = result.object?["byKind"] as? [[String: Any]] ?? []
            #expect(kinds.map { $0["kind"] as? String } == ["text"])
            #expect(kinds.first?["count"] as? Int == 3)
        }
    }

    @Test func statsOnAnEmptyHistoryReportZeroRatherThanFailing() async {
        let result = await CLIProbe.run(["clipboard", "stats", "--json"])
        #expect(result.code == 0)
        #expect(result.object?["count"] as? Int == 0)
        #expect(result.object?["sizeBytes"] as? Int == 0)
        #expect(result.object?["oldest"] as? String == nil)
    }

    @Test func pinningKeepsAnEntryAndMovesItToTheTop() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, count: 3)
            let pinned = await CLIProbe.capture(["clipboard", "pin", "3", "--json"])
            #expect(pinned.code == 0)
            #expect(pinned.object?["pinned"] as? Bool == true)
            #expect(pinned.object?["changed"] as? Bool == true)
            let after = await CLIProbe.capture(["clipboard", "ls", "--json"])
            let rows = after.array as? [[String: Any]] ?? []
            #expect(rows.first?["preview"] as? String == "entry number 1")
            #expect(world.postedNames().contains(IPC.Name.clipboardChanged.rawValue))
        }
    }

    @Test func pinningSomethingAlreadyPinnedSaysSoAndStillSucceeds() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, count: 3)
            let result = await CLIProbe.capture(["clipboard", "pin", "1"])
            #expect(result.code == 0)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("already pinned"))
        }
    }

    @Test func unpinningLetsAnEntryAgeOutAgain() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, count: 3)
            let result = await CLIProbe.capture(["clipboard", "unpin", "1", "--json"])
            #expect(result.object?["pinned"] as? Bool == false)
            #expect(ClipboardRepository.loadEntries().allSatisfy { !$0.pinned })
        }
    }

    @Test func searchingMatchesThePreviewAndTheSourceApp() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, count: 3)
            let hit = await CLIProbe.capture(["clipboard", "ls", "--search", "number 2", "--json"])
            let rows = hit.array as? [[String: Any]] ?? []
            #expect(rows.count == 1)
            #expect(rows.first?["preview"] as? String == "entry number 2")

            let byApp = await CLIProbe.capture(["clipboard", "ls", "--search", "tester", "--json"])
            #expect((byApp.array as? [Any])?.count == 3)

            let miss = await CLIProbe.capture(["clipboard", "ls", "--search", "nope", "--json"])
            #expect((miss.array as? [Any])?.isEmpty == true)
        }
    }

    @Test func copyingAnEntryBumpsItToTheTopTheWayClickingItDoes() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, count: 3)
            _ = await CLIProbe.capture(["clipboard", "unpin", "1", "--json"])
            let before = ClipboardRepository.loadEntries()
                .first { $0.preview == "entry number 0" }
            _ = await CLIProbe.capture(["clipboard", "copy", "3", "--json"])
            let after = ClipboardRepository.loadEntries()
                .first { $0.preview == "entry number 0" }
            #expect(before != nil)
            #expect(after != nil)
            #expect((after?.lastCopiedAt ?? .distantPast) > (before?.lastCopiedAt ?? .distantPast))
            #expect(
                ClipboardActions.arrange(ClipboardRepository.loadEntries()).first?.preview
                    == "entry number 0")
        }
    }

    @Test func aStaleSnapshotCannotClobberAnEntryWrittenAfterIt() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, count: 2)
            let stale = ClipboardRepository.loadEntries()
            let data = Data("arrived later".utf8)
            let sha = ClipboardRepository.sha256Hex(data)
            try ClipboardRepository.writeBlob(data, sha256: sha, ext: "txt")
            try ClipboardRepository.saveEntries(
                stale + [
                    ClipboardEntry(
                        sha256: sha, types: ["public.utf8-plain-text"], ext: "txt",
                        sourceApp: "Tester", sourceBundleID: "test.app",
                        size: data.count, preview: "arrived later")
                ])
            try ClipboardActions.delete(ids: [stale[1].id])
            let previews = ClipboardRepository.loadEntries().compactMap(\.preview)
            #expect(previews.contains("arrived later"))
            #expect(!previews.contains("entry number 1"))
        }
    }

    @Test func anIndexOutsideTheHistoryIsNotFound() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, count: 2)
            for index in ["0", "3", "99"] {
                let result = await CLIProbe.capture(["clipboard", "get", index])
                #expect(result.code == ExitCodes.notFound, "index \(index) exited \(result.code)")
                #expect(result.stderr.contains("numbered from 1"))
            }
        }
    }

    @Test func removingAnEntryLeavesTheRest() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, count: 3)
            let removed = await CLIProbe.capture(["clipboard", "rm", "1", "--json"])
            #expect(removed.object?["remaining"] as? Int == 2)
            let after = await CLIProbe.capture(["clipboard", "ls", "--json"])
            #expect((after.array as? [Any])?.count == 2)
            #expect(world.postedNames().contains(IPC.Name.clipboardChanged.rawValue))
        }
    }

    @Test func clearingCanKeepThePinnedOnes() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, count: 3)
            let result = await CLIProbe.capture([
                "clipboard", "clear", "--keep-pinned", "--json",
            ])
            #expect(result.object?["remaining"] as? Int == 1)
            let after = await CLIProbe.capture(["clipboard", "ls", "--json"])
            let rows = after.array as? [[String: Any]] ?? []
            #expect(rows.count == 1)
            #expect(rows.first?["pinned"] as? Bool == true)
        }
    }

    @Test func clearingWithoutKeepingAnythingEmptiesIt() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, count: 3)
            let result = await CLIProbe.capture(["clipboard", "clear", "--json"])
            #expect(result.object?["removed"] as? Int == 3)
            #expect(result.object?["remaining"] as? Int == 0)
        }
    }

    @Test func aPreviewWithNewlinesNeverBreaksTheTable() async throws {
        try await CLIProbe.inWorld { world in
            let data = Data("first line\nsecond line".utf8)
            let sha = ClipboardRepository.sha256Hex(data)
            try ClipboardRepository.writeBlob(data, sha256: sha, ext: "txt")
            try ClipboardRepository.saveEntries([
                ClipboardEntry(
                    sha256: sha, types: ["public.utf8-plain-text"], ext: "txt",
                    sourceApp: nil, sourceBundleID: nil, size: data.count,
                    preview: "first line\nsecond line")
            ])
            let result = await CLIProbe.capture(["clipboard", "ls"])
            #expect(result.stdoutLines.count == 2)
        }
    }
}

@Suite struct CLIColorTests {
    static func seed(_ world: CLIWorld, count: Int) {
        let swatches = (0..<count).map { index in
            ColorSwatch(
                red: Double(index) / 10, green: 0.5, blue: 1, profile: .sRGB,
                pickedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
        guard let data = try? JSONEncoder().encode(swatches) else { return }
        world.shared.set(data, forKey: "colorPickerHistory")
    }

    @Test func anEmptyHistoryListsNothingRatherThanFailing() async {
        let result = await CLIProbe.run(["color", "ls", "--json"])
        #expect(result.code == 0)
        #expect((result.array as? [Any])?.isEmpty == true)
    }

    @Test func everySwatchCarriesEveryFormat() async throws {
        try await CLIProbe.inWorld { world in
            Self.seed(world, count: 2)
            let result = await CLIProbe.capture(["color", "ls", "--json"])
            let rows = result.array as? [[String: Any]] ?? []
            #expect(rows.count == 2)
            for row in rows {
                #expect(Set(row.keys) == ["hex", "rgb", "hsl", "profile", "pickedAt"])
                #expect((row["hex"] as? String)?.hasPrefix("#") == true)
            }
        }
    }

    @Test func oneFormatPrintsOneColumnOfValues() async throws {
        try await CLIProbe.inWorld { world in
            Self.seed(world, count: 2)
            let result = await CLIProbe.capture(["color", "ls", "--format", "hex"])
            #expect(result.code == 0)
            #expect(result.stdoutLines.count == 2)
            #expect(result.stdoutLines.allSatisfy { $0.hasPrefix("#") })
        }
    }

    @Test func anUnknownFormatIsNotFoundAndListsTheRealOnes() async {
        let result = await CLIProbe.run(["color", "ls", "--format", "cmyk"])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stderr.contains("formats:"))
    }

    @Test func clearingForgetsEverySwatch() async throws {
        try await CLIProbe.inWorld { world in
            Self.seed(world, count: 4)
            let result = await CLIProbe.capture(["color", "clear", "--json"])
            #expect(result.object?["removed"] as? Int == 4)
            #expect(ColorHistoryStore.load(from: world.shared).isEmpty)
        }
    }

    @Test func colourIsSpeltBothWays() throws {
        for name in ["color", "colour"] {
            let parsed = try EdRoot.parseAsRoot([name, "ls"])
            #expect(CommandCrawler.name(of: type(of: parsed)) == "ls")
        }
    }
}

@Suite struct CLIShelfTests {
    static func seed(_ world: CLIWorld, names: [String]) throws {
        try FileManager.default.createDirectory(
            at: ShelfIndex.root, withIntermediateDirectories: true)
        var items: [ShelfItem] = []
        for (index, name) in names.enumerated() {
            try Data("contents of \(name)".utf8).write(
                to: ShelfIndex.root.appendingPathComponent(name))
            items.append(
                ShelfItem(
                    id: UUID(), name: name,
                    addedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))))
        }
        ShelfIndex.save(items)
    }

    @Test func anEmptyShelfListsNothingRatherThanFailing() async {
        let result = await CLIProbe.run(["shelf", "ls", "--json"])
        #expect(result.code == 0)
        #expect((result.array as? [Any])?.isEmpty == true)
    }

    @Test func itemsAreNewestFirstAndCarryTheirPath() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, names: ["one.txt", "two.txt"])
            let result = await CLIProbe.capture(["shelf", "ls", "--json"])
            let rows = result.array as? [[String: Any]] ?? []
            #expect(rows.count == 2)
            #expect(rows.first?["name"] as? String == "two.txt")
            #expect(rows.first?["exists"] as? Bool == true)
            #expect((rows.first?["path"] as? String)?.hasSuffix("two.txt") == true)
        }
    }

    @Test func addingAFileCopiesItOntoTheShelf() async throws {
        try await CLIProbe.inWorld { world in
            let source = world.sandbox.appendingPathComponent("source.txt")
            try Data("hello".utf8).write(to: source)
            let result = await CLIProbe.capture(["shelf", "add", source.path, "--json"])
            #expect(result.code == 0)
            #expect(ShelfIndex.load().count == 1)
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test func addingTheSameNameTwiceNeverOverwrites() async throws {
        try await CLIProbe.inWorld { world in
            let source = world.sandbox.appendingPathComponent("dupe.txt")
            try Data("hello".utf8).write(to: source)
            _ = await CLIProbe.capture(["shelf", "add", source.path])
            _ = await CLIProbe.capture(["shelf", "add", source.path])
            let names = ShelfIndex.load().map(\.name)
            #expect(names.count == 2)
            #expect(Set(names).count == 2)
        }
    }

    @Test func addingAMissingFileIsNotFound() async {
        let result = await CLIProbe.run(["shelf", "add", "/nowhere/at/all.txt"])
        #expect(result.code == ExitCodes.notFound)
    }

    @Test func removingTakesTheFileWithIt() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, names: ["one.txt", "two.txt"])
            let gone = ShelfIndex.root.appendingPathComponent("two.txt")
            let result = await CLIProbe.capture(["shelf", "rm", "1", "--json"])
            #expect(result.object?["remaining"] as? Int == 1)
            #expect(!FileManager.default.fileExists(atPath: gone.path))
        }
    }

    @Test func clearingEmptiesTheWholeShelf() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, names: ["a", "b", "c"])
            let result = await CLIProbe.capture(["shelf", "clear", "--json"])
            #expect(result.object?["removed"] as? Int == 3)
            #expect(ShelfIndex.load().isEmpty)
        }
    }

    @Test func anIndexOutsideTheShelfIsNotFound() async throws {
        try await CLIProbe.inWorld { world in
            try Self.seed(world, names: ["a"])
            let result = await CLIProbe.capture(["shelf", "path", "9"])
            #expect(result.code == ExitCodes.notFound)
        }
    }
}

@Suite struct CLICleanerTests {
    @Test func theCategoryListMatchesTheCatalogTheAppUses() async {
        let result = await CLIProbe.run(["cleaner", "categories", "--json"])
        #expect(result.code == 0)
        let rows = result.array as? [[String: Any]] ?? []
        #expect(rows.compactMap { $0["category"] as? String } == JunkCatalog.entries.map(\.id))
    }

    @Test func anUnknownCategoryIsNotFoundAndListsTheRealOnes() async {
        let result = await CLIProbe.run(["cleaner", "scan", "--category", "bitcoin"])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stderr.contains("categories:"))
    }

    @Test func scanningAHomeWithNoCachesFindsNothing() async throws {
        try await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture(["cleaner", "scan", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["totalBytes"] as? Int == 0)
            #expect((result.object?["categories"] as? [Any])?.isEmpty == true)
        }
    }

    @Test func scanningFindsWhatIsThereAndSizesIt() async throws {
        try await CLIProbe.inWorld { world in
            let cache = world.sandbox.appendingPathComponent("Library/Caches/Homebrew/downloads")
            try FileManager.default.createDirectory(
                at: cache, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 4096).write(
                to: cache.appendingPathComponent("bottle.tar.gz"))
            let result = await CLIProbe.capture([
                "cleaner", "scan", "--category", "homebrew", "--json",
            ])
            #expect(result.code == 0)
            let total = result.object?["totalBytes"] as? Int ?? 0
            #expect(total >= 4096)
            let categories = result.object?["categories"] as? [[String: Any]] ?? []
            #expect(categories.first?["category"] as? String == "homebrew")
        }
    }

    @Test func cleaningRefusesToTouchAnythingWithoutYes() async throws {
        try await CLIProbe.inWorld { world in
            let cache = world.sandbox.appendingPathComponent("Library/Caches/Homebrew/downloads")
            try FileManager.default.createDirectory(
                at: cache, withIntermediateDirectories: true)
            let file = cache.appendingPathComponent("bottle.tar.gz")
            try Data(repeating: 7, count: 4096).write(to: file)
            let result = await CLIProbe.capture([
                "cleaner", "clean", "--category", "homebrew", "--json",
            ])
            #expect(result.code == 0)
            #expect(result.object?["applied"] as? Bool == false)
            #expect(result.object?["reclaimedBytes"] as? Int == 0)
            #expect((result.object?["wouldReclaimBytes"] as? Int ?? 0) >= 4096)
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func theDriveListNamesTheBootVolume() async {
        let result = await CLIProbe.run(["cleaner", "drives", "--json"])
        #expect(result.code == 0)
        let rows = result.array as? [[String: Any]] ?? []
        #expect(rows.contains { $0["id"] as? String == "/" })
    }
}

@Suite struct CLIDockerExtrasTests {
    @Test func everyPruneTargetIsAKnownDockerVerb() {
        for target in DockerPruneCommand.targets {
            let command = DockerCommands.prune(target)
            #expect(command.hasPrefix("docker "))
            #expect(command.contains("prune"))
        }
    }

    @Test func pruningVolumesIsNeverFoldedIntoSystem() {
        #expect(DockerCommands.prune("system") != DockerCommands.prune("volumes"))
        #expect(DockerCommands.prune("volumes").contains("volume prune"))
    }

    @Test func anUnknownPruneTargetIsNotFoundBeforeAnySSH() async {
        let result = await CLIProbe.run([
            "machines", "docker", "prune", "nowhere-at-all", "everything",
        ])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stderr.contains("try:"))
    }

    @Test func everyComposeVerbBuildsACommandScopedToItsProject() {
        for action in ["up -d", "down", "restart", "pull"] {
            let command = DockerCommands.composeAction(
                action, project: "web stack", directory: nil)
            #expect(command.hasPrefix("docker compose -p "))
            #expect(command.contains("'web stack'"))
            #expect(command.hasSuffix(action))
        }
    }

    @Test func composeVerbsAreReachableAsSubcommands() throws {
        for name in ["up", "down", "restart", "pull", "logs"] {
            let parsed = try EdRoot.parseAsRoot([
                "machines", "docker", "compose", name, "m", "p",
            ])
            #expect(CommandCrawler.name(of: type(of: parsed)) == name)
        }
        let listed = try EdRoot.parseAsRoot(["machines", "docker", "compose", "ls", "m"])
        #expect(CommandCrawler.name(of: type(of: listed)) == "ls")
        let bare = try EdRoot.parseAsRoot(["machines", "docker", "compose", "m"])
        #expect(CommandCrawler.name(of: type(of: bare)) == "ls")
    }

    @Test func theMachineMayComeFirstForComposeToo() {
        #expect(
            ArgumentRewriting.rewrite(
                ["machines", "tuf", "docker", "compose", "up", "web"], machines: ["tuf"])
                == ["machines", "docker", "compose", "up", "tuf", "web"])
    }
}

@Suite struct CLIFinderUndoTests {
    @Test func undoSaysToOpenTheAppWhenItIsClosed() async throws {
        try await CLIProbe.inWorld { _ in
            MachineRegistry.add(Machine(name: "Builder", host: "10.0.0.9"))
            CLIEnvironment.isMainAppRunning = { false }
            let result = await CLIProbe.capture(["machines", "files", "undo", "builder"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("Edith is not running"))
            #expect(result.stderr.contains("open Edith"))
        }
    }

    @Test func undoReportsWhenNoWindowHasAnythingToUndo() async throws {
        try await CLIProbe.inWorld { world in
            MachineRegistry.add(Machine(name: "Builder", host: "10.0.0.9"))
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in ["undone": false, "reason": "nothing to undo"] }
            let result = await CLIProbe.capture(["machines", "files", "undo", "builder"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("anything to undo"))
        }
    }

    @Test func undoReportsWhatItUndid() async throws {
        try await CLIProbe.inWorld { world in
            MachineRegistry.add(Machine(name: "Builder", host: "10.0.0.9"))
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in ["undone": true, "label": "Undo Move"] }
            let result = await CLIProbe.capture([
                "machines", "files", "undo", "builder", "--json",
            ])
            #expect(result.code == 0)
            #expect(result.object?["undone"] as? Bool == true)
            #expect(result.object?["what"] as? String == "Undo Move")
        }
    }

    @Test func aMachineThatDoesNotExistIsNotFoundBeforeTheAppIsAsked() async throws {
        try await CLIProbe.inWorld { _ in
            CLIEnvironment.isMainAppRunning = { false }
            let result = await CLIProbe.capture(["machines", "files", "undo", "nope"])
            #expect(result.code == ExitCodes.notFound)
        }
    }
}

@Suite struct CLIClipboardIndexTruthTests {
    private func seed(_ count: Int) throws {
        var entries: [ClipboardEntry] = []
        for index in 0..<count {
            let text = index % 2 == 0 ? "alpha \(index)" : "beta \(index)"
            let data = Data(text.utf8)
            let sha = ClipboardRepository.sha256Hex(data)
            try ClipboardRepository.writeBlob(data, sha256: sha, ext: "txt")
            entries.append(
                ClipboardEntry(
                    sha256: sha, types: ["public.utf8-plain-text"], ext: "txt",
                    sourceApp: index % 2 == 0 ? "Alpha" : "Beta", sourceBundleID: "test",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    size: data.count, preview: text))
        }
        try ClipboardRepository.saveEntries(entries)
    }

    @Test func theNumberAFilteredListPrintsIsTheNumberGetTakes() async throws {
        try await CLIProbe.inWorld { _ in
            try seed(6)
            let listed = await CLIProbe.capture([
                "clipboard", "ls", "--search", "alpha", "--json",
            ])
            let rows = listed.array as? [[String: Any]] ?? []
            #expect(!rows.isEmpty)
            for row in rows {
                guard let index = row["index"] as? Int,
                    let preview = row["preview"] as? String
                else { continue }
                let fetched = await CLIProbe.capture(["clipboard", "get", String(index)])
                #expect(
                    fetched.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == preview,
                    "index \(index) printed \(preview) but get returned \(fetched.stdout)")
            }
        }
    }

    @Test func theNumberAPinnedListPrintsIsTheNumberUnpinTakes() async throws {
        try await CLIProbe.inWorld { _ in
            try seed(6)
            let all = ClipboardActions.arrange(ClipboardRepository.loadEntries())
            try ClipboardActions.setPinned(true, ids: [all[3].id])
            let listed = await CLIProbe.capture(["clipboard", "ls", "--pinned", "--json"])
            let rows = listed.array as? [[String: Any]] ?? []
            #expect(rows.count == 1)
            guard let index = rows.first?["index"] as? Int else { return }
            let unpinned = await CLIProbe.capture([
                "clipboard", "unpin", String(index), "--json",
            ])
            #expect(unpinned.object?["changed"] as? Bool == true)
            #expect(ClipboardRepository.loadEntries().allSatisfy { !$0.pinned })
        }
    }

    @Test func filteringNeverRenumbersWhatIsLeft() async throws {
        try await CLIProbe.inWorld { _ in
            try seed(6)
            let everything = await CLIProbe.capture(["clipboard", "ls", "--limit", "0", "--json"])
            let byID = Dictionary(
                uniqueKeysWithValues: (everything.array as? [[String: Any]] ?? []).compactMap {
                    row -> (String, Int)? in
                    guard let id = row["id"] as? String, let index = row["index"] as? Int
                    else { return nil }
                    return (id, index)
                })
            let filtered = await CLIProbe.capture([
                "clipboard", "ls", "--search", "beta", "--json",
            ])
            for row in filtered.array as? [[String: Any]] ?? [] {
                guard let id = row["id"] as? String, let index = row["index"] as? Int else {
                    continue
                }
                #expect(
                    byID[id] == index, "\(id) is \(byID[id] ?? -1) unfiltered but \(index) filtered"
                )
            }
        }
    }

    @Test func aValueOutsideWhatAnOptionAcceptsIsAUsageError() async {
        for arguments in [
            ["clipboard", "ls", "--limit=-1"], ["color", "ls", "--limit=-1"],
            ["music", "seek", "1.5"], ["music", "volume", "9"],
        ] {
            let result = await CLIProbe.run(arguments)
            #expect(result.code == ExitCodes.usage, "\(arguments) exited \(result.code)")
            #expect(result.stdout.isEmpty)
        }
    }

    @Test func zeroMeansEverythingForColoursJustAsItDoesForTheClipboard() async {
        let result = await CLIProbe.run(["color", "ls", "--limit", "0", "--json"])
        #expect(result.code == 0)
        #expect(result.array != nil)
    }

    @Test func aMistypedConfigSubcommandIsNotAnEmptyListing() async {
        for typo in ["lst", "exprot", "describ"] {
            let result = await CLIProbe.run(["config", typo])
            #expect(result.code == ExitCodes.notFound, "\(typo) exited \(result.code)")
            #expect(result.stdout.isEmpty)
        }
    }
}

@Suite struct RemoteUploadDestinationTests {
    @Test func aTrailingSlashMeansPutItInThatDirectory() {
        #expect(RemoteDestination.joined("/tmp/uploads", "clip.mov") == "/tmp/uploads/clip.mov")
    }

    @Test func aNameWithSpacesSurvivesBeingJoined() {
        #expect(
            RemoteDestination.joined("/home/pulkit/Desktop/uploads", "Screen Recording 1.mov")
                == "/home/pulkit/Desktop/uploads/Screen Recording 1.mov")
    }

    @Test func aBareSlashStillProducesAnAbsolutePath() {
        #expect(RemoteDestination.joined("", "clip.mov") == "/clip.mov")
    }
}
