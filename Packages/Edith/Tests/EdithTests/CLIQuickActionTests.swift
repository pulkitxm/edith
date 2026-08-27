import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIQuickActionTests {
    final class State: @unchecked Sendable {
        var appearance = QuickActionAppearance.light
        var keyboardLevel: Float? = 0.5
        var hiddenFiles = false
        var desktopIcons = true
        var volumes = [(URL(fileURLWithPath: "/Volumes/Backup"), "Backup")]
        var emptiedTrash = false
        var locked = false
    }

    @Test func statusReportsEveryStateAndVisibilityAsOneDocument() async {
        await CLIProbe.inWorld { world in
            let state = State()
            configure(world, state: state)
            world.shared.set(false, forKey: AppStorageKeys.QuickActions.keyboardLight)

            let result = await CLIProbe.capture(["quick-actions", "status", "--json"])

            #expect(result.code == 0)
            #expect(result.stderr.isEmpty)
            #expect(result.object?["enabled"] as? Bool == true)
            let snapshot = result.object?["snapshot"] as? [String: Any]
            #expect(snapshot?["appearance"] as? String == "light")
            #expect(snapshot?["keyboardLightAvailable"] as? Bool == true)
            #expect(snapshot?["hiddenFilesShown"] as? Bool == false)
            let actions = result.object?["actions"] as? [[String: Any]]
            #expect(actions?.count == QuickAction.allCases.count)
            let keyboard = actions?.first { $0["id"] as? String == "keyboard-light" }
            #expect(keyboard?["visible"] as? Bool == false)
        }
    }

    @Test func reversibleCommandsMutateSharedOperationState() async {
        await CLIProbe.inWorld { world in
            let state = State()
            configure(world, state: state)

            let appearance = await CLIProbe.capture(["quick-actions", "appearance", "--json"])
            let hidden = await CLIProbe.capture(["quick-actions", "hidden-files", "--json"])
            let desktop = await CLIProbe.capture(["quick-actions", "desktop-icons", "--json"])
            let keyboard = await CLIProbe.capture([
                "quick-actions", "keyboard-light", "--json",
            ])

            for result in [appearance, hidden, desktop, keyboard] {
                #expect(result.code == 0)
                #expect(result.object?["applied"] as? Bool == true)
                #expect(result.object?["changed"] as? Bool == true)
            }
            #expect(state.appearance == .dark)
            #expect(state.hiddenFiles)
            #expect(!state.desktopIcons)
            #expect(state.keyboardLevel == 0)
        }
    }

    @Test func trashPreviewsWithoutMutationAndRequiresYesToApply() async {
        await CLIProbe.inWorld { world in
            let state = State()
            configure(world, state: state)

            let preview = await CLIProbe.capture(["quick-actions", "empty-trash", "--json"])
            #expect(preview.code == 0)
            #expect(preview.object?["applied"] as? Bool == false)
            #expect(preview.object?["changed"] as? Bool == false)
            #expect(!state.emptiedTrash)

            let applied = await CLIProbe.capture([
                "quick-actions", "empty-trash", "--yes", "--json",
            ])
            #expect(applied.code == 0)
            #expect(applied.object?["applied"] as? Bool == true)
            #expect(applied.object?["changed"] as? Bool == true)
            #expect(state.emptiedTrash)
        }
    }

    @Test func operationalCommandsReportCountsAndLockState() async {
        await CLIProbe.inWorld { world in
            let state = State()
            configure(world, state: state)

            let eject = await CLIProbe.capture(["quick-actions", "eject-disks", "--json"])
            let lock = await CLIProbe.capture(["quick-actions", "lock-screen", "--json"])

            #expect(eject.object?["affectedCount"] as? Int == 1)
            #expect(state.volumes.isEmpty)
            #expect(lock.object?["operation"] as? String == "quick-actions.lock-screen")
            #expect(state.locked)
        }
    }

    @Test func actionsRejectAnInactiveExtension() async {
        let result = await CLIProbe.run(["quick-actions", "hidden-files", "--json"])
        #expect(result.code == ExitCodes.unavailable)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("Quick Actions extension is off"))
    }

    @Test func parserAndCommandTreeCoverEveryOperation() throws {
        #expect(
            try EdRoot.parseAsRoot(["quick-actions", "appearance"])
                is QuickActionsAppearanceCommand)
        #expect(
            try EdRoot.parseAsRoot(["quick-actions", "keyboard-light"])
                is QuickActionsKeyboardLightCommand)
        #expect(
            try EdRoot.parseAsRoot(["quick-actions", "empty-trash"])
                is QuickActionsEmptyTrashCommand)
        for action in QuickAction.allCases {
            let leaf = try #require(
                CommandTree.root.child("quick-actions")?.child(commandName(action)))
            #expect(leaf.children.isEmpty)
            #expect(leaf.options.contains("--json"))
        }
    }

    private func configure(_ world: CLIWorld, state: State) {
        world.shared.set(true, forKey: AppStorageKeys.Tabs.quickActionsEnabled)
        CLIEnvironment.quickActionCenter = {
            QuickActionCenter(
                environment: QuickActionEnvironment(
                    appearance: { state.appearance },
                    toggleAppearance: {
                        state.appearance = state.appearance == .dark ? .light : .dark
                    },
                    keyboardLight: { state.keyboardLevel },
                    setKeyboardLight: {
                        state.keyboardLevel = $0
                        return true
                    },
                    finderFlag: { key, fallback in
                        switch key {
                        case "AppleShowAllFiles": state.hiddenFiles
                        case "CreateDesktop": state.desktopIcons
                        default: fallback
                        }
                    },
                    setFinderFlag: { key, value in
                        if key == "AppleShowAllFiles" { state.hiddenFiles = value }
                        if key == "CreateDesktop" { state.desktopIcons = value }
                    },
                    volumes: { state.volumes.map { (url: $0.0, name: $0.1) } },
                    eject: { url in state.volumes.removeAll { $0.0 == url } },
                    emptyTrash: { state.emptiedTrash = true },
                    lockScreen: { state.locked = true }))
        }
    }

    private func commandName(_ action: QuickAction) -> String {
        action.descriptor.cli.last ?? action.rawValue
    }
}
