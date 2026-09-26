import AppKit
import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite struct BrowserShortcutMatrixTests {
    private func match(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> BrowserShortcut? {
        BrowserShortcut.match(characters: key, modifiers: modifiers)
    }

    @Test func everyCommandKeyMapsToExactlyOneAction() {
        let expected: [(String, BrowserShortcut)] = [
            ("t", .newTab), ("w", .closeTab), ("l", .focusAddress), ("r", .reload),
            ("[", .back), ("\u{F702}", .back), ("]", .forward), ("\u{F703}", .forward),
            ("=", .zoomIn), ("+", .zoomIn), ("-", .zoomOut), ("0", .zoomReset),
            ("c", .copy), ("x", .cut), ("v", .paste), ("a", .selectAll), ("z", .undo),
            ("9", .lastTab),
        ]
        for (key, action) in expected {
            #expect(match(key, .command) == action, "cmd+\(key)")
            #expect(match(key.uppercased(), .command) == action, "cmd+\(key.uppercased())")
        }
        for digit in 1...8 {
            #expect(match(String(digit), .command) == .selectTab(digit - 1))
        }
    }

    @Test func everyCommandShiftKeyMapsToExactlyOneAction() {
        let expected: [(String, BrowserShortcut)] = [
            ("t", .reopenClosedTab), ("r", .hardReload), ("z", .redo),
            ("[", .previousTab), ("{", .previousTab), ("]", .nextTab), ("}", .nextTab),
            ("=", .zoomIn), ("+", .zoomIn),
        ]
        for (key, action) in expected {
            #expect(match(key, [.command, .shift]) == action, "cmd+shift+\(key)")
        }
        for key in ["w", "l", "c", "v", "a", "-", "0", "1", "9"] {
            #expect(match(key, [.command, .shift]) == nil, "cmd+shift+\(key)")
        }
    }

    @Test func tabCyclingUsesControlAndCommandOptionArrows() {
        #expect(match("\t", .control) == .nextTab)
        #expect(match("\t", [.control, .shift]) == .previousTab)
        #expect(match("\u{19}", [.control, .shift]) == .previousTab)
        #expect(match("\u{F703}", [.command, .option]) == .nextTab)
        #expect(match("\u{F702}", [.command, .option]) == .previousTab)
        #expect(match("t", .control) == nil)
        #expect(match("t", [.control, .shift]) == nil)
        #expect(match("\t", [.command, .option]) == nil)
    }

    @Test func otherModifierCombinationsAndDigitsOutOfRangeAreIgnored() {
        for key in ["t", "w", "1", "9", "\t"] {
            #expect(match(key, []) == nil)
            #expect(match(key, .option) == nil)
            #expect(match(key, .shift) == nil)
            #expect(match(key, [.command, .control]) == nil)
            #expect(match(key, [.command, .shift, .option]) == nil)
        }
        #expect(match("0", .command) == .zoomReset)
        #expect(match("10", .command) == nil)
        #expect(match("", .command) == nil)
    }

    @Test func modifiersOutsideTheMatchedSetDoNotChangeTheResult() {
        #expect(match("t", [.command, .capsLock]) == .newTab)
        #expect(match("t", [.command, .numericPad, .function]) == .newTab)
    }

    @Test func onlyEditingShortcutsCarryAResponderAction() {
        let editing: [BrowserShortcut] = [.copy, .cut, .paste, .selectAll, .undo, .redo]
        for shortcut in editing { #expect(shortcut.editAction != nil) }
        let navigation: [BrowserShortcut] = [
            .newTab, .closeTab, .reopenClosedTab, .focusAddress, .reload, .hardReload, .back,
            .forward, .nextTab, .previousTab, .selectTab(3), .lastTab, .zoomIn, .zoomOut,
            .zoomReset,
        ]
        for shortcut in navigation { #expect(shortcut.editAction == nil) }
    }
}

@Suite struct NotchBrowserGeometryEdgeTests {
    private let start = CGSize(width: 900, height: 600)
    private let screen = CGSize(width: 1512, height: 982)
    private let origin = CGPoint(x: 0, y: 0)

    @Test func draggingUpPastTheMinimumStopsAtTheMinimumHeight() {
        let size = NotchBrowserGeometry.resized(
            from: start, edge: .bottom, pointerStart: origin, pointer: CGPoint(x: 0, y: 5000),
            screen: screen)
        #expect(size == CGSize(width: 900, height: NotchBrowserGeometry.minimumSize.height))
    }

    @Test func draggingDownPastTheScreenStopsAtTheScreenMaximum() {
        let size = NotchBrowserGeometry.resized(
            from: start, edge: .bottom, pointerStart: origin, pointer: CGPoint(x: 0, y: -5000),
            screen: screen)
        #expect(size.height == NotchBrowserGeometry.maximumSize(screen: screen).height)
        #expect(size.height == screen.height - NotchBrowserGeometry.screenMargin.height)
    }

    @Test func cornersClampWidthInBothDirections() {
        let wide = NotchBrowserGeometry.resized(
            from: start, edge: .bottomTrailing, pointerStart: origin,
            pointer: CGPoint(x: 5000, y: 0), screen: screen)
        #expect(wide.width == screen.width - 2 * NotchBrowserGeometry.screenMargin.width)
        let narrow = NotchBrowserGeometry.resized(
            from: start, edge: .bottomTrailing, pointerStart: origin,
            pointer: CGPoint(x: -5000, y: 0), screen: screen)
        #expect(narrow.width == NotchBrowserGeometry.minimumSize.width)
        let leadingNarrow = NotchBrowserGeometry.resized(
            from: start, edge: .bottomLeading, pointerStart: origin,
            pointer: CGPoint(x: 5000, y: 0), screen: screen)
        #expect(leadingNarrow.width == NotchBrowserGeometry.minimumSize.width)
    }

    @Test func withoutAScreenTheUpperBoundIsTheHardCap() {
        let size = NotchBrowserGeometry.resized(
            from: start, edge: .bottomTrailing, pointerStart: origin,
            pointer: CGPoint(x: 5000, y: -5000), screen: nil)
        #expect(size == CGSize(width: 4096, height: 4096))
    }

    @Test func fractionalPointerDeltasProduceWholePointSizes() {
        let size = NotchBrowserGeometry.resized(
            from: start, edge: .bottomTrailing, pointerStart: CGPoint(x: 0.25, y: 0.75),
            pointer: CGPoint(x: 10.6, y: -3.4), screen: screen)
        #expect(size.width == size.width.rounded())
        #expect(size.height == size.height.rounded())
        #expect(size == CGSize(width: 921, height: 604))
    }

    @Test func aTinyScreenStillAllowsTheMinimumBrowser() {
        let tiny = CGSize(width: 300, height: 200)
        #expect(NotchBrowserGeometry.maximumSize(screen: tiny) == NotchBrowserGeometry.minimumSize)
        #expect(
            NotchBrowserGeometry.clamp(CGSize(width: 1, height: 1), screen: tiny)
                == NotchBrowserGeometry.minimumSize)
        #expect(NotchBrowserGeometry.available(screen: tiny, notchHeight: 500).height == 0)
    }
}

@Suite struct ChromeProfileParserOrderingTests {
    private func localState(order: [String]?, cache: [String: [String: Any]]) throws -> Data {
        var profile: [String: Any] = ["info_cache": cache]
        if let order { profile["profiles_order"] = order }
        return try JSONSerialization.data(withJSONObject: ["profile": profile])
    }

    @Test func orderedProfilesComeFirstAndTheRestFollowDefaultThenNaturalOrder() throws {
        let cache: [String: [String: Any]] = [
            "Profile 10": ["name": "Ten"], "Profile 2": ["name": "Two"],
            "Default": ["name": "Zero"], "Profile 1": ["name": "One"],
            "Profile 3": ["name": "Three"],
        ]
        let data = try localState(order: ["Profile 3", "Missing", "Profile 1"], cache: cache)
        let profiles = ChromeProfileParser.profiles(
            localState: data, root: URL(fileURLWithPath: "/chrome"), exists: { _ in true })
        #expect(
            profiles.map(\.directory) == [
                "Profile 3", "Profile 1", "Default", "Profile 2", "Profile 10",
            ])
    }

    @Test func unicodeNamesAndEmailsSurviveParsingAndDriveInitials() throws {
        let cache: [String: [String: Any]] = [
            "Default": ["name": "Éla Müller", "user_name": "éla@exämple.com"],
            "Profile 1": ["name": "李 小龍"],
            "Profile 2": ["name": "🐙 Octo_Pus"],
            "Profile 3": ["name": "  "],
        ]
        let data = try localState(order: nil, cache: cache)
        let profiles = ChromeProfileParser.profiles(
            localState: data, root: URL(fileURLWithPath: "/chrome"), exists: { _ in true })
        #expect(profiles.map(\.name) == ["Éla Müller", "李 小龍", "🐙 Octo_Pus", "Profile 3"])
        #expect(profiles[0].email == "éla@exämple.com")
        #expect(profiles.map(\.initials) == ["ÉM", "李小", "🐙O", "P3"])
    }

    @Test func missingFoldersAreDroppedWithoutDisturbingTheOrder() throws {
        let cache: [String: [String: Any]] = [
            "Default": ["name": "A"], "Profile 1": ["name": "B"], "Profile 2": ["name": "C"],
        ]
        let data = try localState(order: ["Profile 2", "Default", "Profile 1"], cache: cache)
        let profiles = ChromeProfileParser.profiles(
            localState: data, root: URL(fileURLWithPath: "/chrome"),
            exists: { !$0.lastPathComponent.hasPrefix("Default") })
        #expect(profiles.map(\.directory) == ["Profile 2", "Profile 1"])
    }
}

@Suite struct BrowserSessionFileTests {
    private func temporaryFile() -> BrowserSessionFile {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-session-\(UUID().uuidString)", isDirectory: true)
        return BrowserSessionFile(url: folder.appendingPathComponent("session.json"))
    }

    @Test func corruptOrForeignJSONLoadsAsAnEmptySession() throws {
        for payload in ["{", "[]", "null", "{\"tabs\": \"nope\"}", "", "\u{FF}"] {
            let file = temporaryFile()
            try FileManager.default.createDirectory(
                at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(payload.utf8).write(to: file.url)
            #expect(file.load() == BrowserSession(), "payload \(payload)")
            file.remove()
        }
    }

    @Test func missingFilesLoadAsAnEmptySessionAndRemoveIsIdempotent() {
        let file = temporaryFile()
        #expect(file.load() == BrowserSession())
        file.remove()
        file.remove()
        #expect(file.load() == BrowserSession())
    }

    @Test func unknownKeysAreIgnoredAndOptionalSizeStaysAbsent() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(
            at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
            {"profile": "Default", "tabs": ["https://a.com/"], "selected": 0, "future": 1}
            """
        try Data(json.utf8).write(to: file.url)
        let session = file.load()
        #expect(session.profile == "Default")
        #expect(session.tabs == ["https://a.com/"])
        #expect(session.size == nil)
        file.remove()
    }

    @Test func savingRoundTripsUnicodeTabsAndCreatesTheFolder() {
        let file = temporaryFile()
        var session = BrowserSession()
        session.profile = "Profile 1"
        session.tabs = ["https://ex%C3%A4mple.com/%E8%B7%AF?q=%F0%9F%90%99", "about:blank"]
        session.selected = 1
        session.width = 1000.5
        session.height = 700
        file.save(session)
        let loaded = file.load()
        #expect(loaded == session)
        #expect(loaded.size == CGSize(width: 1000.5, height: 700))
        #expect(loaded.restorableURLs.map(\.absoluteString) == [session.tabs[0]])
        file.remove()
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }
}

@Suite struct LocalStorageSeedEscapingTests {
    @Test func scriptClosingTagsAndQuotesCannotBreakOutOfTheScript() throws {
        let script = try #require(
            LocalStorageSeed.script(
                origin: "https://a.com\"</script>",
                items: ["</script><script>alert(1)</script>": "\"'</SCRIPT>\\"]))
        #expect(!script.contains("</script>"))
        #expect(!script.contains("</SCRIPT>"))
        #expect(script.contains("<\\/script>"))
        #expect(script.contains("\\\"'<\\/SCRIPT>\\\\"))
    }

    @Test func unicodeKeysAndValuesArePreservedVerbatim() throws {
        let script = try #require(
            LocalStorageSeed.script(
                origin: "https://exämple.com", items: ["ключ": "值 🐙", "\u{2028}": "\u{0}"]))
        #expect(script.contains("\"ключ\":\"值 🐙\""))
        #expect(script.contains("\\u0000"))
        #expect(script.contains("\"https:\\/\\/exämple.com\""))
    }

    @Test func itemsAreSerializedInSortedKeyOrderForStableScripts() throws {
        let items = ["b": "2", "a": "1", "c": "3"]
        let first = try #require(LocalStorageSeed.script(origin: "https://a.com", items: items))
        let second = try #require(LocalStorageSeed.script(origin: "https://a.com", items: items))
        #expect(first == second)
        #expect(first.contains("{\"a\":\"1\",\"b\":\"2\",\"c\":\"3\"}"))
    }

    @Test func importableDropsEmptyAndOversizedOriginsOnly() {
        let big = String(repeating: "x", count: LocalStorageSeed.originLimitBytes)
        let importable = LocalStorageSeed.importable([
            "https://empty.com": [:],
            "https://big.com": ["k": big],
            "https://fine.com": ["k": "v"],
        ])
        #expect(importable.keys.sorted() == ["https://fine.com"])
    }
}

@Suite struct NotchHoverGateReentrancyTests {
    @Test func flippingTheTargetWhilePendingReplacesTheSchedule() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        #expect(gate.sample(.open, now: 0) == .schedule(deadline: 0.1))
        #expect(gate.sample(.outside, now: 0.02) == .cancelPending)
        #expect(gate.hasPending == false)
        #expect(gate.sample(.open, now: 2) == .schedule(deadline: 2.1))
        #expect(gate.fire(now: 2.05) == .schedule(deadline: 2.1))
        #expect(gate.fire(now: 2.1) == .opened)
    }

    @Test func firingTwiceOnlyTransitionsOnce() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        _ = gate.sample(.open, now: 0)
        #expect(gate.fire(now: 1) == .opened)
        #expect(gate.fire(now: 2) == .none)
        #expect(gate.isOpen)
    }

    @Test func forcingAStateWhilePendingDropsTheTimer() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        _ = gate.sample(.open, now: 0)
        gate.forceOpen()
        #expect(gate.hasPending == false)
        #expect(gate.fire(now: 5) == .none)
        _ = gate.sample(.outside, now: 6)
        gate.forceClosed()
        #expect(gate.hasPending == false)
        #expect(gate.fire(now: 7) == .none)
        #expect(gate.isOpen == false)
    }

    @Test func aLateSampleOfTheSameTargetKeepsTheOriginalDeadline() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        #expect(gate.sample(.open, now: 0) == .schedule(deadline: 0.1))
        #expect(gate.sample(.open, now: 0.5) == .none)
        #expect(gate.fire(now: 0.5) == .opened)
    }

    @Test func changingTheCloseGraceAppliesToTheNextSchedule() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        gate.forceOpen()
        #expect(gate.sample(.outside, now: 1) == .schedule(deadline: 1.4))
        gate.closeGrace = 0.9
        #expect(gate.sample(.keepOpen, now: 1.1) == .cancelPending)
        #expect(gate.sample(.outside, now: 1.2) == .schedule(deadline: 2.1))
    }

    @Test func negativeTimingsClampToZeroAndFireImmediately() {
        var gate = NotchHoverGate(openDwell: -1, closeGrace: -1)
        #expect(gate.openDwell == 0)
        #expect(gate.closeGrace == 0)
        #expect(gate.sample(.open, now: 3) == .schedule(deadline: 3))
        #expect(gate.fire(now: 3) == .opened)
    }
}
