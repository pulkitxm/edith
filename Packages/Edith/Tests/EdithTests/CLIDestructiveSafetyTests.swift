import Foundation
import Testing

@testable import EdithCLI
@testable import EdithCore
@testable import EdithKit

@Suite struct CLIDestructiveSafetyTests {
    static let destructivePaths: Set<String> = [
        "ed app clear-updates",
        "ed app quit",
        "ed app relaunch",
        "ed apps quit",
        "ed cleaner clean",
        "ed clipboard clear",
        "ed clipboard rm",
        "ed color clear",
        "ed companion erase",
        "ed companion forget",
        "ed companion db rebuild-derived",
        "ed companion db reindex",
        "ed companion stack down",
        "ed companion wipe",
        "ed download clear",
        "ed download rm",
        "ed lid-awake on",
        "ed lid-awake restore-on-quit",
        "ed machines docker prune",
        "ed machines docker rm",
        "ed machines docker rmi",
        "ed machines docker volume-rm",
        "ed machines files cp",
        "ed machines files get",
        "ed machines files get-many",
        "ed machines files mv",
        "ed machines files put",
        "ed machines files rm",
        "ed machines files transfer",
        "ed machines kill",
        "ed machines control airplane",
        "ed machines control wifi",
        "ed machines power reboot",
        "ed machines power shutdown",
        "ed machines rm",
        "ed music rm",
        "ed quinjet close",
        "ed shelf clear",
        "ed shelf purge",
        "ed shelf rm",
        "ed text snippets rm",
    ]

    static func nodes(
        under node: CommandNode = CommandTree.root, path: [String] = []
    ) -> [(String, CommandNode)] {
        let here = path + [node.name]
        return [(here.joined(separator: " "), node)]
            + node.children.flatMap { nodes(under: $0, path: here) }
    }

    @Test func everyDestructiveLeafDeclaresThePreviewThenYesPolicy() {
        let nodes = Self.nodes()
        let marked = Set(
            nodes.compactMap { path, node in
                node.destructivePolicy == .previewThenYes ? path : nil
            })
        #expect(marked == Self.destructivePaths)
        for (path, node) in nodes {
            #expect(
                node.options.contains("--yes") == (node.destructivePolicy == .previewThenYes),
                "\(path) has inconsistent destructive metadata")
            if node.destructivePolicy != nil {
                #expect(node.children.isEmpty, "\(path) is not a leaf")
            }
        }
    }

    @Test func migratedParsersExposeAnExplicitConfirmationFlag() throws {
        let docker = try #require(
            try EdRoot.parseAsRoot(["machines", "docker", "rm", "box", "api", "--yes"])
                as? DockerRemoveCommand)
        let image = try #require(
            try EdRoot.parseAsRoot([
                "machines", "docker", "rmi", "box", "nginx", "--yes",
            ]) as? DockerRemoveImageCommand)
        let kill = try #require(
            try EdRoot.parseAsRoot([
                "machines", "kill", "box", "42", "--signal", "KILL", "--yes",
            ]) as? MachinesKillCommand)
        let stack = try #require(
            try EdRoot.parseAsRoot(["companion", "stack", "down", "--wipe", "--yes"])
                as? CompanionStackDownCommand)
        let forget = try #require(
            try EdRoot.parseAsRoot(["companion", "forget", "abc", "--yes"])
                as? CompanionForgetCommand)
        let reindex = try #require(
            try EdRoot.parseAsRoot(["companion", "db", "reindex", "--yes"])
                as? CompanionDbReindexCommand)
        let rebuild = try #require(
            try EdRoot.parseAsRoot(["companion", "db", "rebuild-derived", "--yes"])
                as? CompanionDbRebuildCommand)
        let shelfRemove = try #require(
            try EdRoot.parseAsRoot(["shelf", "rm", "1", "--yes"])
                as? ShelfRemoveCommand)
        let shelfClear = try #require(
            try EdRoot.parseAsRoot(["shelf", "clear", "--yes"])
                as? ShelfClearCommand)
        let shelfPurge = try #require(
            try EdRoot.parseAsRoot(["shelf", "purge", "oneDay", "--yes"])
                as? ShelfPurgeCommand)
        let clipboard = try #require(
            try EdRoot.parseAsRoot(["clipboard", "clear", "--yes"])
                as? ClipboardClearCommand)
        let clipboardRemove = try #require(
            try EdRoot.parseAsRoot(["clipboard", "rm", "1", "--yes"])
                as? ClipboardRemoveCommand)
        let color = try #require(
            try EdRoot.parseAsRoot(["color", "clear", "--yes"])
                as? ColorClearCommand)
        let appQuit = try #require(
            try EdRoot.parseAsRoot(["app", "quit", "--yes"]) as? AppQuitCommand)
        let appRelaunch = try #require(
            try EdRoot.parseAsRoot(["app", "relaunch", "--yes"]) as? AppRelaunchCommand)
        let appClear = try #require(
            try EdRoot.parseAsRoot(["app", "clear-updates", "--yes"])
                as? AppClearUpdateHistoryCommand)
        #expect(
            docker.yes && image.yes && kill.yes && stack.yes && forget.yes && reindex.yes
                && rebuild.yes)
        #expect(
            shelfRemove.yes && shelfClear.yes && shelfPurge.yes && clipboard.yes
                && clipboardRemove.yes && color.yes)
        #expect(appQuit.yes && appRelaunch.yes && appClear.yes)
    }

    @Test func appRuntimePreviewsDoNotQuitLaunchOrClearHistory() async {
        await CLIProbe.inWorld { world in
            let app = world.sandbox.appendingPathComponent("Edith.app")
            CLIEnvironment.installedAppURL = { app }
            let historyURL = CLIEnvironment.updateHistoryURL()
            let record = UpdateCheckRecord(
                date: Date(timeIntervalSince1970: 1), kind: .manual, outcome: .upToDate)
            UpdateCheckLog.append(record, to: historyURL)

            let quit = await CLIProbe.capture(["app", "quit", "--json"])
            let relaunch = await CLIProbe.capture(["app", "relaunch", "--json"])
            let clear = await CLIProbe.capture(["app", "clear-updates", "--json"])

            for result in [quit, relaunch, clear] {
                #expect(result.code == 0)
                #expect(result.object?["applied"] as? Bool == false)
                #expect(result.object?["changed"] as? Bool == false)
            }
            #expect(quit.object?["requested"] as? Bool == false)
            #expect(relaunch.object?["relaunched"] as? Bool == false)
            #expect(relaunch.object?["path"] as? String == app.path)
            #expect(clear.object?["removed"] as? Int == 1)
            #expect(world.postedNames().isEmpty)
            #expect(UpdateCheckLog.load(from: historyURL) == [record])

            let applied = await CLIProbe.capture([
                "app", "clear-updates", "--yes", "--json",
            ])
            #expect(applied.object?["applied"] as? Bool == true)
            #expect(applied.object?["changed"] as? Bool == true)
            #expect(applied.object?["removed"] as? Int == 1)
            #expect(UpdateCheckLog.load(from: historyURL).isEmpty)
        }
    }

    @Test func previewDescriptorsResolveToConfirmedCommandLeaves() {
        for descriptor in UserOperationCatalog.descriptors where descriptor.requiresPreview {
            let node = descriptor.cli.reduce(Optional(CommandTree.root)) { node, component in
                node?.child(component)
            }
            #expect(node?.destructivePolicy == .previewThenYes)
            #expect(node?.options.contains("--yes") == true)
        }
    }

    @Test func destructiveLifecycleRecoveryCommandsRequireConfirmation() {
        var destructiveCommands: [String] = []
        for descriptor in ExtensionLifecycleCatalog.descriptors {
            for command in descriptor.recovery.compactMap(\.command) {
                let words = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                var node = Optional(CommandTree.root)
                for word in words.dropFirst() {
                    guard let child = node?.child(word) else { break }
                    node = child
                }
                guard node?.destructivePolicy == .previewThenYes else { continue }
                destructiveCommands.append(command)
                #expect(words.contains("--yes"), "\(command) only previews its recovery")
            }
        }
        #expect(!destructiveCommands.isEmpty)
    }

    @Test func clipboardPreviewPreservesIndexAndBlobsThenConfirmationRemovesOnlyTargets()
        async throws
    {
        try await CLIProbe.inWorld { world in
            try CLIClipboardTests.seed(world, count: 3)
            let before = try Data(contentsOf: ClipboardPaths.indexFile)
            let entries = ClipboardBridge.entries()
            let blobBytes = try Dictionary(
                uniqueKeysWithValues: entries.map {
                    (
                        $0.id,
                        try Data(
                            contentsOf: ClipboardPaths.blobFile(sha256: $0.sha256, ext: $0.ext))
                    )
                })
            let preview = await CLIProbe.capture([
                "clipboard", "clear", "--keep-pinned", "--json",
            ])
            #expect(preview.object?["applied"] as? Bool == false)
            #expect(preview.object?["changed"] as? Bool == false)
            let targets = Set(preview.object?["targets"] as? [String] ?? [])
            #expect(targets == Set(entries.filter { !$0.pinned }.map(\.id)))
            #expect(try Data(contentsOf: ClipboardPaths.indexFile) == before)
            for entry in entries {
                #expect(
                    try Data(
                        contentsOf: ClipboardPaths.blobFile(
                            sha256: entry.sha256, ext: entry.ext)) == blobBytes[entry.id])
            }

            let applied = await CLIProbe.capture([
                "clipboard", "clear", "--keep-pinned", "--yes", "--json",
            ])
            #expect(applied.object?["applied"] as? Bool == true)
            #expect(applied.object?["changed"] as? Bool == true)
            let remaining = ClipboardRepository.loadEntries()
            #expect(remaining.map(\.id) == entries.filter(\.pinned).map(\.id))
            #expect(Set(entries.map(\.id)).subtracting(remaining.map(\.id)) == targets)
        }
    }

    @Test func clipboardRemovePreviewsTheExactEntryBeforeDeletingIt() async throws {
        try await CLIProbe.inWorld { world in
            try CLIClipboardTests.seed(world, count: 2)
            let entries = ClipboardBridge.entries()
            let target = entries[0]
            let blob = ClipboardPaths.blobFile(sha256: target.sha256, ext: target.ext)
            let before = try Data(contentsOf: ClipboardPaths.indexFile)

            let preview = await CLIProbe.capture(["clipboard", "rm", "1", "--json"])
            #expect(preview.object?["applied"] as? Bool == false)
            #expect(preview.object?["changed"] as? Bool == false)
            #expect(preview.object?["targets"] as? [String] == [target.id])
            #expect(try Data(contentsOf: ClipboardPaths.indexFile) == before)
            #expect(FileManager.default.fileExists(atPath: blob.path))

            let applied = await CLIProbe.capture([
                "clipboard", "rm", "1", "--yes", "--json",
            ])
            #expect(applied.object?["applied"] as? Bool == true)
            #expect(applied.object?["changed"] as? Bool == true)
            #expect(applied.object?["remaining"] as? Int == 1)
            #expect(!ClipboardRepository.loadEntries().contains { $0.id == target.id })
            #expect(!FileManager.default.fileExists(atPath: blob.path))
        }
    }

    @Test func shelfPreviewPreservesBytesThenConfirmationRemovesOnlyNamedItem() async throws {
        try await CLIProbe.inWorld { world in
            try CLIShelfTests.seed(world, names: ["one.txt", "two.txt"])
            let items = try ShelfBridge.items()
            let beforeIndex = try Data(contentsOf: ShelfIndex.indexFile())
            let beforeFiles = try Dictionary(
                uniqueKeysWithValues: items.map {
                    ($0.id, try Data(contentsOf: ShelfIndex.fileURL(for: $0)))
                })
            let preview = await CLIProbe.capture(["shelf", "rm", "1", "--json"])
            #expect(preview.object?["applied"] as? Bool == false)
            #expect(preview.object?["changed"] as? Bool == false)
            let target = try #require((preview.object?["targets"] as? [String])?.only)
            #expect(target == ShelfIndex.fileURL(for: items[0]).path)
            #expect(try Data(contentsOf: ShelfIndex.indexFile()) == beforeIndex)
            for item in items {
                #expect(try Data(contentsOf: ShelfIndex.fileURL(for: item)) == beforeFiles[item.id])
            }

            let applied = await CLIProbe.capture(["shelf", "rm", "1", "--yes", "--json"])
            #expect(applied.object?["applied"] as? Bool == true)
            #expect(applied.object?["changed"] as? Bool == true)
            #expect(!FileManager.default.fileExists(atPath: target))
            let kept = try #require(ShelfIndex.load().only)
            #expect(kept.id == items[1].id)
            #expect(try Data(contentsOf: ShelfIndex.fileURL(for: kept)) == beforeFiles[kept.id])
        }
    }

    @Test func shelfAndColorClearPreviewWithoutChangingTheirStores() async throws {
        try await CLIProbe.inWorld { world in
            try CLIShelfTests.seed(world, names: ["one.txt", "two.txt"])
            CLIColorTests.seed(world, count: 2)
            let shelfIndex = try Data(contentsOf: ShelfIndex.indexFile())
            let colorData = try #require(world.shared.data(forKey: "colorPickerHistory"))

            let shelf = await CLIProbe.capture(["shelf", "clear", "--json"])
            let color = await CLIProbe.capture(["color", "clear", "--json"])
            #expect(shelf.object?["applied"] as? Bool == false)
            #expect(color.object?["applied"] as? Bool == false)
            #expect(try Data(contentsOf: ShelfIndex.indexFile()) == shelfIndex)
            #expect(world.shared.data(forKey: "colorPickerHistory") == colorData)

            let applied = await CLIProbe.capture(["color", "clear", "--yes", "--json"])
            #expect(applied.object?["applied"] as? Bool == true)
            #expect(applied.object?["changed"] as? Bool == true)
            #expect(ColorHistoryStore.load(from: world.shared).isEmpty)
            #expect(try Data(contentsOf: ShelfIndex.indexFile()) == shelfIndex)
        }
    }

    @Test func remotePreviewsResolveExactTargetsWithoutOpeningAConnection() async {
        await CLIProbe.inWorld { _ in
            MachineRegistry.add(Machine(name: "Build Box", host: "192.0.2.7"))
            let cases: [([String], String)] = [
                (
                    ["machines", "docker", "rm", "build", "api", "worker", "--json"],
                    "Build Box:container:api"
                ),
                (
                    ["machines", "docker", "rmi", "build", "nginx:latest", "--json"],
                    "Build Box:image:nginx:latest"
                ),
                (
                    ["machines", "kill", "build", "42", "--signal", "KILL", "--json"],
                    "Build Box:pid:42"
                ),
            ]
            for (arguments, firstTarget) in cases {
                let result = await CLIProbe.capture(arguments)
                #expect(result.code == 0, "\(arguments) exited \(result.code)")
                #expect(result.object?["applied"] as? Bool == false)
                #expect(result.object?["changed"] as? Bool == false)
                #expect((result.object?["targets"] as? [String])?.first == firstTarget)
            }
        }
    }

    @Test func companionPreviewsDoNotContactTheServiceOrRunTheStack() async {
        await CLIProbe.inWorld { _ in
            let conversation = await CLIProbe.capture([
                "companion", "forget", "conversation-7", "--json",
            ])
            #expect(conversation.code == 0)
            #expect(conversation.object?["applied"] as? Bool == false)
            #expect(conversation.object?["targets"] as? [String] == ["conversation-7"])

            CompanionDeploymentStore.save(
                CompanionDeployment(
                    machineID: nil, machineName: "This Mac", directory: "/srv/edith",
                    tier: "cpu"))
            let stack = await CLIProbe.capture([
                "companion", "stack", "down", "--wipe", "--json",
            ])
            #expect(stack.code == 0)
            #expect(stack.object?["applied"] as? Bool == false)
            #expect(stack.object?["changed"] as? Bool == false)
            #expect(
                stack.object?["targets"] as? [String]
                    == ["This Mac:/srv/edith:volumes"])
        }
    }

    @Test func plainPreviewNamesTargetsAndExplainsConfirmation() async throws {
        try await CLIProbe.inWorld { world in
            try CLIShelfTests.seed(world, names: ["one.txt"])
            let target = ShelfIndex.root.appendingPathComponent("one.txt").path
            let result = await CLIProbe.capture(["shelf", "rm", "1"])
            #expect(result.code == 0)
            #expect(result.stdout == "would remove shelf item: \(target)\n")
            #expect(result.stderr == "nothing changed; pass --yes to apply this plan\n")
            #expect(FileManager.default.fileExists(atPath: target))
        }
    }
}

extension Array {
    fileprivate var only: Element? { count == 1 ? first : nil }
}
