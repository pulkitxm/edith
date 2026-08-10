import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@Suite struct SectionWindowTests {
    @Test func commandClickDetaches() {
        #expect(SectionWindowCommand.shouldDetach(.command))
        #expect(SectionWindowCommand.shouldDetach([.command, .shift]))
        #expect(!SectionWindowCommand.shouldDetach([]))
        #expect(!SectionWindowCommand.shouldDetach(.option))
    }

    @Test func filesIsNotATabBecauseItOpensItsOwnWindow() {
        #expect(!MachineTab.allCases.map(\.rawValue).contains("files"))
        #expect(
            MachineTab.tabs(isLocal: true, hasDocker: true) == [.overview, .processes, .terminal])
        #expect(MachineTab.tabs(isLocal: false, hasDocker: true).contains(.docker))
    }

    @Test func machinesWithoutDockerInstalledHideTheDockerTab() {
        #expect(!MachineTab.tabs(isLocal: false, hasDocker: false).contains(.docker))
        #expect(MachineTab.tabs(isLocal: false, hasDocker: false).contains(.overview))
        #expect(!PaneScreen.available(isLocal: false, hasDocker: false).contains(.docker))
        #expect(PaneScreen.available(isLocal: false, hasDocker: true).contains(.docker))
        #expect(!DockerAvailability(status: .missing).isInstalled)
        #expect(DockerAvailability(status: .unknown).isInstalled)
        #expect(DockerAvailability(status: .permissionDenied).isInstalled)
    }

    @Test func everyVisibleSectionExceptAboutCanDetach() {
        let visible: [MainDestination] = [.home, .dashboard, .machines]
        let detachable = SectionWindowCommand.detachableDestinations(visibleHomeItems: visible)
        #expect(detachable.contains(.machines))
        #expect(detachable.contains(.extensions))
        #expect(detachable.contains(.settings))
        #expect(!detachable.contains(.about))
    }

    @Test func detachableListFollowsEnabledExtensions() {
        let detachable = SectionWindowCommand.detachableDestinations(visibleHomeItems: [.home])
        #expect(!detachable.contains(.music))
        #expect(detachable.first == .home)
    }
}

@Suite struct WindowTabKeyCommandTests {
    @Test func controlTabCyclesTabsOnlyWhenTabbed() {
        #expect(
            WindowTabKeyCommand.resolve(
                characters: "\t", keyCode: 48, modifiers: .control, tabbed: true) == .nextTab)
        #expect(
            WindowTabKeyCommand.resolve(
                characters: "\t", keyCode: 48, modifiers: [.control, .shift], tabbed: true)
                == .previousTab)
        #expect(
            WindowTabKeyCommand.resolve(
                characters: "\t", keyCode: 48, modifiers: .control, tabbed: false) == nil)
    }

    @Test func commandNumberSelectsTabByIndex() {
        #expect(
            WindowTabKeyCommand.resolve(
                characters: "1", keyCode: 18, modifiers: .command, tabbed: true)
                == .selectTab(index: 0))
        #expect(
            WindowTabKeyCommand.resolve(
                characters: "9", keyCode: 25, modifiers: .command, tabbed: true)
                == .selectTab(index: 8))
    }

    @Test func commandNumberIsLeftToTheSidebarWhenNotTabbed() {
        #expect(
            WindowTabKeyCommand.resolve(
                characters: "1", keyCode: 18, modifiers: .command, tabbed: false) == nil)
    }

    @Test func ignoresOutOfRangeAndExtraModifiers() {
        #expect(
            WindowTabKeyCommand.resolve(
                characters: "0", keyCode: 29, modifiers: .command, tabbed: true) == nil)
        #expect(
            WindowTabKeyCommand.resolve(
                characters: "1", keyCode: 18, modifiers: [.command, .option], tabbed: true)
                == nil)
        #expect(
            WindowTabKeyCommand.resolve(
                characters: "a", keyCode: 0, modifiers: .command, tabbed: true) == nil)
    }

    @Test func controlTabIsNotConfusedWithCommandTab() {
        #expect(
            WindowTabKeyCommand.resolve(
                characters: "\t", keyCode: 48, modifiers: [.control, .command], tabbed: true)
                == nil)
    }
}

@Suite struct FinderKeyTests {
    private func event(
        keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    @Test func returnRenamesAndCommandReturnOpens() {
        #expect(FinderKey.resolve(event: event(keyCode: 36)) == .rename)
        #expect(
            FinderKey.resolve(event: event(keyCode: 36, modifiers: .command)) == .openSelection)
    }

    @Test func arrowsMoveAndExtendSelection() {
        #expect(FinderKey.resolve(event: event(keyCode: 125)) == .move(.down, extend: false))
        #expect(
            FinderKey.resolve(event: event(keyCode: 125, modifiers: .shift))
                == .move(.down, extend: true))
        #expect(
            FinderKey.resolve(event: event(keyCode: 126, modifiers: .command))
                == .enclosingFolder)
    }

    @Test func spaceIsQuickLookAndEscapeCancels() {
        #expect(FinderKey.resolve(event: event(keyCode: 49)) == .quickLook)
        #expect(FinderKey.resolve(event: event(keyCode: 53)) == .cancel)
    }

    @Test func deleteNeedsCommandAndOptionMeansImmediate() {
        #expect(FinderKey.resolve(event: event(keyCode: 51)) == nil)
        #expect(FinderKey.resolve(event: event(keyCode: 51, modifiers: .command)) == .trash)
        #expect(
            FinderKey.resolve(event: event(keyCode: 51, modifiers: [.command, .option]))
                == .deleteImmediately)
    }

    @Test func commandLettersMapToActions() {
        #expect(
            FinderKey.resolve(event: event(keyCode: 8, characters: "c", modifiers: .command))
                == .copy)
        #expect(
            FinderKey.resolve(
                event: event(keyCode: 8, characters: "c", modifiers: [.command, .option]))
                == .copyPath)
        #expect(
            FinderKey.resolve(
                event: event(keyCode: 45, characters: "n", modifiers: [.command, .shift]))
                == .newFolder)
        #expect(
            FinderKey.resolve(event: event(keyCode: 18, characters: "1", modifiers: .command))
                == .iconView)
    }

    @Test func plainLettersTypeSelect() {
        #expect(FinderKey.resolve(event: event(keyCode: 0, characters: "a")) == .type("a"))
        #expect(
            FinderKey.resolve(event: event(keyCode: 0, characters: "a", modifiers: .option))
                == nil)
    }
}

@Suite @MainActor struct QuickLookSelectionTests {
    private func finder() -> FinderModel {
        let session = MachinesModel.shared.session(for: MachinesModel.localMachineID)
        let model = FinderModel(session: session)
        model.entries = [
            RemoteFileEntry(name: "a.txt", path: "/d/a.txt", kind: .file, sizeBytes: 1),
            RemoteFileEntry(name: "b.txt", path: "/d/b.txt", kind: .file, sizeBytes: 2),
            RemoteFileEntry(name: "c.txt", path: "/d/c.txt", kind: .file, sizeBytes: 3),
        ]
        return model
    }

    @Test func previewFollowsANewSelectionWhileItIsOpen() {
        let model = finder()
        model.selection = ["/d/a.txt"]
        model.toggleQuickLook()
        #expect(model.quickLookPath == "/d/a.txt")

        model.selection = ["/d/b.txt"]
        #expect(model.quickLookPath == "/d/b.txt")

        model.moveSelection(by: 1, extend: false)
        #expect(model.quickLookPath == "/d/c.txt")
    }

    @Test func selectionChangesDoNotOpenAClosedPreview() {
        let model = finder()
        model.selection = ["/d/a.txt"]
        #expect(model.quickLookPath == nil)
        model.selection = ["/d/b.txt"]
        #expect(model.quickLookPath == nil)
    }

    @Test func previewOpensOnTheSelectedFileAndClosesAgain() {
        let model = finder()
        model.selection = ["/d/c.txt"]
        model.toggleQuickLook()
        #expect(model.quickLookPath == "/d/c.txt")
        model.toggleQuickLook()
        #expect(model.quickLookPath == nil)
    }
}

@Suite struct WorkspaceKeyCommandTests {
    @Test func commandOptionArrowsWalkPaneTabs() {
        #expect(
            WorkspaceKeyCommand.resolve(
                characters: nil, keyCode: 124, modifiers: [.command, .option]) == .nextPaneTab)
        #expect(
            WorkspaceKeyCommand.resolve(
                characters: nil, keyCode: 123, modifiers: [.command, .option])
                == .previousPaneTab)
    }

    @Test func commandControlArrowsMovePaneFocus() {
        #expect(
            WorkspaceKeyCommand.resolve(
                characters: nil, keyCode: 124, modifiers: [.command, .control]) == .nextPane)
        #expect(
            WorkspaceKeyCommand.resolve(
                characters: nil, keyCode: 123, modifiers: [.command, .control]) == .previousPane)
    }

    @Test func commandShiftBracketsWalkTerminalTabs() {
        #expect(
            WorkspaceKeyCommand.resolve(
                characters: "]", keyCode: 30, modifiers: [.command, .shift]) == .nextTerminalTab)
        #expect(
            WorkspaceKeyCommand.resolve(
                characters: "[", keyCode: 33, modifiers: [.command, .shift])
                == .previousTerminalTab)
    }

    @Test func plainArrowsAndSingleModifiersAreLeftAlone() {
        #expect(WorkspaceKeyCommand.resolve(characters: nil, keyCode: 124, modifiers: []) == nil)
        #expect(
            WorkspaceKeyCommand.resolve(characters: nil, keyCode: 124, modifiers: .command) == nil)
        #expect(
            WorkspaceKeyCommand.resolve(
                characters: nil, keyCode: 125, modifiers: [.command, .option]) == nil)
        #expect(
            WorkspaceKeyCommand.resolve(characters: "]", keyCode: 30, modifiers: .command) == nil)
    }
}

@Suite @MainActor struct WorkspaceNavigationTests {
    private func model() -> WorkspaceModel {
        let machine = UUID()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-workspace-\(UUID().uuidString).json")
        let model = WorkspaceModel(machines: .shared, file: file)
        var layout = WorkspaceLayout.single(machineID: machine, screen: .overview)
        model.use(layout)
        guard let pane = layout.root.panes.first else { return model }
        model.addTab(to: pane.id, target: PaneTarget(machineID: machine, screen: .processes))
        model.addTab(to: pane.id, target: PaneTarget(machineID: machine, screen: .terminal))
        layout = model.layout
        return model
    }

    @Test func tabCyclingWrapsAroundThePane() {
        let model = model()
        guard let pane = model.layout.root.panes.first else { return }
        let order = pane.tabs.map(\.id)
        #expect(order.count == 3)
        #expect(model.layout.root.panes.first?.selected == order[2])

        #expect(model.cycleTab(backwards: false))
        #expect(model.layout.root.panes.first?.selected == order[0])
        #expect(model.cycleTab(backwards: true))
        #expect(model.layout.root.panes.first?.selected == order[2])
    }

    @Test func paneFocusMovesBetweenSplits() {
        let model = model()
        guard let pane = model.layout.root.panes.first else { return }
        let target = PaneTarget(machineID: UUID(), screen: .overview)
        model.apply { $0.split(paneID: pane.id, side: .right, target: target) }
        let panes = model.layout.root.panes
        #expect(panes.count == 2)

        model.apply { $0.focused = panes[0].id }
        #expect(model.cyclePane(backwards: false))
        #expect(model.layout.focused == panes[1].id)
        #expect(model.cyclePane(backwards: false))
        #expect(model.layout.focused == panes[0].id)
    }

    @Test func aSinglePaneWithOneTabHasNothingToCycle() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-workspace-\(UUID().uuidString).json")
        let model = WorkspaceModel(machines: .shared, file: file)
        model.use(WorkspaceLayout.single(machineID: UUID(), screen: .overview))
        #expect(!model.cycleTab(backwards: false))
        #expect(!model.cyclePane(backwards: false))
    }
}

@Suite struct ModifierNormalisationTests {
    @Test func capsLockDoesNotBreakAChord() {
        let withCaps: NSEvent.ModifierFlags = [.command, .capsLock]
        #expect(withCaps.chordOnly == .command)
        #expect(withCaps.chordOnly != withCaps)
    }

    @Test func arrowKeyFunctionFlagsAreIgnored() {
        let arrow: NSEvent.ModifierFlags = [.command, .option, .function, .numericPad]
        #expect(arrow.chordOnly == [.command, .option])
        #expect(
            WorkspaceKeyCommand.resolve(characters: nil, keyCode: 124, modifiers: arrow)
                == .nextPaneTab)
    }

    @Test func terminalTabsMatchByKeyCodeBecauseShiftRewritesTheCharacter() {
        #expect(
            WorkspaceKeyCommand.resolve(
                characters: "}", keyCode: 30, modifiers: [.command, .shift]) == .nextTerminalTab)
        #expect(
            WorkspaceKeyCommand.resolve(
                characters: "{", keyCode: 33, modifiers: [.command, .shift])
                == .previousTerminalTab)
    }

    @Test func windowTabShortcutsSurviveCapsLock() {
        #expect(
            WindowTabKeyCommand.resolve(
                characters: "2", keyCode: 19, modifiers: [.command, .capsLock], tabbed: true)
                == .selectTab(index: 1))
    }
}

@Suite @MainActor struct DockerLogPresentationTests {
    private let lines = [
        DockerLogLine(id: 0, timestamp: "2026-08-07T10:00:00Z", text: "starting", isStderr: false),
        DockerLogLine(id: 1, timestamp: "2026-08-07T10:00:01Z", text: "boom", isStderr: true),
    ]

    @Test func plainTextCarriesEveryVisibleLineForCopying() {
        let model = DockerDetailModel()
        model.logs = lines
        model.showTimestamps = false
        #expect(model.logPlainText == "starting\nboom")

        model.showTimestamps = true
        #expect(model.logPlainText.contains("2026-08-07T10:00:00Z  starting"))
    }

    @Test func theFilterNarrowsWhatIsCopiedAsWellAsWhatIsShown() {
        let model = DockerDetailModel()
        model.logs = lines
        model.showTimestamps = false
        model.logFilter = "boom"
        #expect(model.visibleLogs.count == 1)
        #expect(model.logPlainText == "boom")
    }

    @Test func theLogDocumentChangesWhenAnyPresentationOptionChanges() {
        let base = LogDocument(lines: lines, showTimestamps: false, wraps: true, fontSize: 11)
        #expect(
            base != LogDocument(lines: lines, showTimestamps: true, wraps: true, fontSize: 11))
        #expect(
            base != LogDocument(lines: lines, showTimestamps: false, wraps: false, fontSize: 11))
        #expect(
            base != LogDocument(lines: lines, showTimestamps: false, wraps: true, fontSize: 13))
    }
}

@Suite struct FinderArrowKeyTests {
    private func event(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode)!
    }

    @Test func horizontalArrowsMoveAndCommandArrowsNavigate() {
        #expect(FinderKey.resolve(event: event(keyCode: 123)) == .move(.left, extend: false))
        #expect(FinderKey.resolve(event: event(keyCode: 124)) == .move(.right, extend: false))
        #expect(
            FinderKey.resolve(event: event(keyCode: 123, modifiers: .shift))
                == .move(.left, extend: true))
        #expect(FinderKey.resolve(event: event(keyCode: 123, modifiers: .command)) == .back)
        #expect(FinderKey.resolve(event: event(keyCode: 124, modifiers: .command)) == .forward)
    }

    @Test func duplicateUndoAndInvertHaveShortcuts() {
        func key(_ character: String, _ modifiers: NSEvent.ModifierFlags) -> FinderKey? {
            FinderKey.resolve(
                event: NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: 0, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!)
        }
        #expect(key("d", .command) == .duplicate)
        #expect(key("z", .command) == .undo)
        #expect(key("z", [.command, .shift]) == .redo)
        #expect(key("a", .command) == .selectAll)
        #expect(key("a", [.command, .shift]) == .invertSelection)
    }
}

@Suite @MainActor struct LogTextViewIncrementalTests {
    private func line(_ id: Int, _ text: String) -> DockerLogLine {
        DockerLogLine(id: id, timestamp: "t\(id)", text: text, isStderr: false)
    }

    private func controller(_ lines: [DockerLogLine], font: Double = 11) -> LogTextViewController {
        let controller = LogTextViewController()
        controller.loadView()
        controller.apply(
            LogDocument(lines: lines, showTimestamps: false, wraps: true, fontSize: font),
            palette: palette, follow: false)
        return controller
    }

    private let palette = LogPalette(
        text: .white, stderr: .red, timestamp: .gray, background: .black)

    @Test func appendingLinesKeepsWhatWasAlreadyRendered() {
        let controller = controller([line(0, "alpha"), line(1, "beta")])
        #expect(controller.renderedText == "alpha\nbeta\n")

        controller.apply(
            LogDocument(
                lines: [line(0, "alpha"), line(1, "beta"), line(2, "gamma")],
                showTimestamps: false, wraps: true, fontSize: 11),
            palette: palette, follow: false)
        #expect(controller.renderedText == "alpha\nbeta\ngamma\n")
    }

    @Test func trimmingTheFrontDropsExactlyTheOldestLines() {
        let controller = controller([line(0, "one"), line(1, "two"), line(2, "three")])
        controller.apply(
            LogDocument(
                lines: [line(1, "two"), line(2, "three"), line(3, "four")],
                showTimestamps: false, wraps: true, fontSize: 11),
            palette: palette, follow: false)
        #expect(controller.renderedText == "two\nthree\nfour\n")
    }

    @Test func aChangedFilterRebuildsRatherThanAppending() {
        let controller = controller([line(0, "alpha"), line(1, "beta"), line(2, "gamma")])
        controller.apply(
            LogDocument(lines: [line(1, "beta")], showTimestamps: false, wraps: true, fontSize: 11),
            palette: palette, follow: false)
        #expect(controller.renderedText == "beta\n")
    }

    @Test func changingPresentationRebuildsWithTheNewFormatting() {
        let controller = controller([line(0, "alpha")])
        #expect(controller.renderedText == "alpha\n")
        controller.apply(
            LogDocument(lines: [line(0, "alpha")], showTimestamps: true, wraps: true, fontSize: 11),
            palette: palette, follow: false)
        #expect(controller.renderedText == "t0  alpha\n")
    }

    @Test func clearingEverythingEmptiesTheView() {
        let controller = controller([line(0, "alpha"), line(1, "beta")])
        controller.apply(
            LogDocument(lines: [], showTimestamps: false, wraps: true, fontSize: 11),
            palette: palette, follow: false)
        #expect(controller.renderedText.isEmpty)
    }
}
