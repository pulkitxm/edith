import EdithExtensionSupport
import Foundation
import Testing
@testable import BifrostExtension

@Suite(.serialized) @MainActor struct BifrostParityTests {
    @Test func hotKeyModifiersAndLabelAreSynchronized() throws {
        let mods = AppStorageKeys.Bifrost.hotKeyMods
        let label = AppStorageKeys.Bifrost.hotKeyLabel
        #expect(BifrostUIContext.keys.contains(mods))
        #expect(BifrostUIContext.keys.contains(label))
        try BifrostUIContext.set(mods, value: "256")
        try BifrostUIContext.set(label, value: "⌘K")
        #expect(SharedDefaults.store.integer(forKey: mods) == 256)
        #expect(SharedDefaults.store.string(forKey: label) == "⌘K")
        SharedDefaults.store.removeObject(forKey: mods)
        SharedDefaults.store.removeObject(forKey: label)
    }

    @Test func shellCommandsMergeStandardErrorAndKeepTheUserPath() async throws {
        let merged = try await BifrostCommandExecution.run(
            "echo out; echo err >&2", timeout: 20
        ).get()
        #expect(merged.contains("out") && merged.contains("err"))
        let path = try await BifrostCommandExecution.run("echo $PATH", timeout: 20).get()
        #expect(path.contains("/opt/homebrew/bin"))
        let failure = await BifrostCommandExecution.run("echo boom >&2; exit 3", timeout: 20)
        guard case .failure(let error) = failure else {
            Issue.record("Expected a failure")
            return
        }
        #expect(error.localizedDescription.contains("boom"))
    }

    @Test func largeOutputIsNotCapped() async throws {
        let output = try await BifrostCommandExecution.run(
            "head -c 6000000 /dev/zero | tr '\\0' 'a'", timeout: 30
        ).get()
        #expect(output.utf8.count == 6_000_000)
    }

    @Test func commandsRouteThroughPeerAndPanelEndpoints() {
        let commands = Dictionary(
            uniqueKeysWithValues: BifrostCommandCatalog.commands.map { ($0.id, $0) })
        #expect(commands["emoji.pick"]?.abilityID == "emoji")
        #expect(commands["color.pick"]?.abilityID == "colorPicker")
        #expect(commands["panel.open"]?.abilityID == nil)
    }
}
