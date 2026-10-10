import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import EmojiExtension

@MainActor @Suite(.serialized) struct EmojiCLITests {

    @Test func discoveryCatalogContainsOnlyOriginalParserRoutesAndRejectsForeignPayloads()
        throws
    {
        let data = try EmojiCLIExecution.catalog(Data("{}".utf8))
        let catalog = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["version"] as? Int == 1)
        #expect(catalog["owner"] as? String == "emoji")
        #expect(catalog["acceptsInput"] as? Bool == false)
        let commands = try #require(catalog["commands"] as? [[String: Any]])
        let routes = commands.compactMap { $0["route"] as? [String] }
        var expected: [[String]] = [
            ["emoji"], ["emoji", "pick"], ["emoji", "ls"], ["emoji", "insert"], ["emoji", "tone"],
            ["emoji", "forget"], ["emoji", "clear"],
        ]
        expected.append(["emoji", "help"])
        #expect(Set(routes) == Set(expected))
        #expect(routes.count == Set(routes).count)
        #expect(commands.allSatisfy { $0["operation"] as? String == "emoji.cli" })
        let documents = try #require(catalog["parserHelp"] as? [[String: Any]])
        #expect(documents.count == 1)
        #expect(documents[0]["serializationVersion"] as? Int == 0)
        let help = try #require(documents[0]["command"] as? [String: Any])
        #expect(help["commandName"] as? String == "emoji")

        #expect(throws: (any Error).self) {
            try EmojiCLIExecution.catalog(Data("{\"arguments\":[]}".utf8))
        }
    }

    @Test func originalActionReceivesTheExactCallerContextAndDoesNotLeakIt() async throws {
        let request = try ExtensionCLIRequest(
            arguments: ["insert", "1F44D"], standardInput: Data("synthetic terminal input".utf8),
            workingDirectory: "/tmp/synthetic-terminal-context", interactive: true)
        var observed: ExtensionCLIRequest?
        let defaults = UserDefaults(suiteName: "edith.emoji.context." + UUID().uuidString)!
        defaults.set(true, forKey: AppStorageKeys.Emoji.enabled)
        let reply = try await EmojiCLIExecution.run(
            request, defaults: defaults, catalog: catalog(), pick: {},
            insert: { _ in
                observed = ExtensionCLIContext.request; return true
            }, changed: {})
        #expect(reply.exitCode == 0)
        #expect(observed == request)
        #expect(ExtensionCLIContext.request == nil)
    }
    private func catalog() throws -> EmojiCatalog {
        try EmojiCatalog.decode(
            Data(
                """
                {"schema":1,"source":"fixture","groups":[{"id":"people-body","name":"People","symbol":"hand.wave"}],
                "emoji":[{"e":"👍","n":"thumbs up","g":0,"v":0.6,"t":["thumbsup"],"s":["👍🏻","👍🏼","👍🏽","👍🏾","👍🏿"]}]}
                """.utf8))
    }

    @Test func originalSearchToneInsertForgetClearAndPickUseOwnedModels() async throws {
        let defaults = UserDefaults(suiteName: "edith.emoji.cli." + UUID().uuidString)!
        defaults.set(true, forKey: AppStorageKeys.Emoji.enabled)
        let catalog = try catalog()
        var inserted: [String] = []
        var picks = 0
        let store = EmojiStore(
            defaults: defaults, writePasteboard: { _ in false }, catalog: catalog,
            insertionDelay: .zero,
            typeCharacter: {
                inserted.append($0); return true
            })
        defer { store.shutdown() }
        func run(_ arguments: [String]) async throws -> ExtensionCLIReply {
            try await EmojiCLIExecution.run(
                ExtensionCLIRequest(arguments: arguments), defaults: defaults,
                catalog: catalog, pick: { picks += 1 },
                insert: { try await store.insertAndWait(character: $0) },
                changed: { store.adoptSettings() })
        }
        let list = try await run(["ls", "--search", "thumbsup", "--group", "people-body"])
        #expect(list.stdout == "👍  thumbs up\n")
        let tone = try await run(["tone", "medium"])
        #expect(tone.stdout == "skin tone set to medium ✋🏽\n")
        let insert = try await run(["insert", "1F44D"])
        #expect(insert.stdout == "inserted 👍🏽\n")
        #expect(inserted == ["👍🏽"])
        #expect(store.frequent.count == 1)
        let forget = try await run(["forget", "1F44D"])
        #expect(forget.stdout == "forgot 👍🏽\n")
        #expect(store.frequent.isEmpty)
        _ = try await run(["insert", "👍"])
        let clear = try await run(["clear"])
        #expect(clear.stdout == "cleared 1 frequently used emoji\n")
        #expect(store.frequent.isEmpty)
        let pick = try await run(["pick"])
        #expect(pick.stdout == "emoji picker requested\n" && picks == 1)
        let badGroup = try await run(["ls", "--group", "foreign"])
        #expect(badGroup.exitCode == 3)
        let badLimit = try await run(["ls", "--limit", "-1"])
        #expect(badLimit.exitCode == 2)
        defaults.set(false, forKey: AppStorageKeys.Emoji.enabled)
        let disabled = try await run(["insert", "👍"])
        #expect(disabled.exitCode == 4 && inserted.count == 2)
    }

    @Test func cancellationAndDisablePreventDelayedInsertion() async throws {
        let defaults = UserDefaults(suiteName: "edith.emoji.cli." + UUID().uuidString)!
        var inserts = 0
        let store = EmojiStore(
            defaults: defaults, catalog: try catalog(), insertionDelay: .seconds(10),
            typeCharacter: { _ in
                inserts += 1; return true
            })
        let insertion = Task { try await store.insertAndWait(character: "👍") }
        await Task.yield()
        insertion.cancel()
        do {
            _ = try await insertion.value; Issue.record("cancelled insertion returned successfully")
        } catch is CancellationError {} catch { Issue.record("unexpected error: \(error)") }
        #expect(inserts == 0)
        store.shutdown()
        #expect(try await store.insertAndWait(character: "👍") == false)
        #expect(inserts == 0)
    }
}
