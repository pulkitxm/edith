import Carbon.HIToolbox
import Foundation
import Testing

@testable import EdithHost

@Suite struct HostShortcutConflictsTests {
    private func owners(defaults: UserDefaults) -> [HostShortcutOwner] {
        let panel = HostShortcutConflicts.panel
        return [
            HostShortcutConflicts.owner(
                title: panel.title, prefix: panel.prefix, defaultCode: panel.code,
                defaultModifiers: panel.modifiers, defaults: defaults)
        ]
            + HostExtensionShortcut.allCases.map {
                HostShortcutConflicts.owner(
                    title: $0.title, prefix: $0.prefix, defaultCode: $0.defaultCode,
                    defaultModifiers: $0.defaultModifiers, defaults: defaults)
            }
    }

    private func scratchDefaults() throws -> (UserDefaults, String) {
        let name = "com.pulkit.edith.tests.shortcut-conflicts-" + UUID().uuidString
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func theShippedDefaultsNeverCollide() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let all = owners(defaults: defaults)
        for owner in all {
            #expect(
                HostShortcutConflicts.owner(
                    code: owner.code, modifiers: owner.modifiers, excluding: owner.prefix,
                    among: all) == nil, "\(owner.title)")
        }
    }

    @Test func aRecordedShortcutAnotherExtensionHoldsIsRejectedByName() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let found = HostShortcutConflicts.owner(
            code: kVK_ANSI_E, modifiers: controlKey | shiftKey, excluding: "clipboardHotKey",
            among: owners(defaults: defaults))
        #expect(found?.title == "Emoji picker")
        #expect(HostShortcutConflicts.message(try #require(found)).contains("Emoji picker"))
    }

    @Test func anExtensionsOwnShortcutIsNotAConflictWithItself() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(
            HostShortcutConflicts.owner(
                code: kVK_ANSI_E, modifiers: controlKey | shiftKey, excluding: "emojiHotKey",
                among: owners(defaults: defaults)) == nil)
    }

    @Test func storedShortcutsReplaceTheDefaultsWhenLookingForConflicts() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(kVK_ANSI_J, forKey: "emojiHotKeyCode")
        defaults.set(cmdKey | shiftKey, forKey: "emojiHotKeyMods")
        let all = owners(defaults: defaults)
        #expect(
            HostShortcutConflicts.owner(
                code: kVK_ANSI_E, modifiers: controlKey | shiftKey, excluding: "clipboardHotKey",
                among: all) == nil)
        #expect(
            HostShortcutConflicts.owner(
                code: kVK_ANSI_J, modifiers: cmdKey | shiftKey, excluding: "clipboardHotKey",
                among: all)?.title == "Emoji picker")
    }

    @Test func thePanelShortcutIsProtectedFromExtensions() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(
            HostShortcutConflicts.owner(
                code: kVK_ANSI_E, modifiers: optionKey | cmdKey, excluding: "emojiHotKey",
                among: owners(defaults: defaults))?.title == "Open panel")
    }
}
