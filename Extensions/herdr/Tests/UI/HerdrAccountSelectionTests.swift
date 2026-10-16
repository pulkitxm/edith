import EdithExtensionAccounts
import EdithExtensionSupport
import Foundation
import Testing
@testable import HerdrUI

private actor HerdrSelectionNotifications {
    var invalidations = 0
    var refreshes = 0
    func invalidate() { invalidations += 1 }
    func refresh() { refreshes += 1 }
}

@MainActor @Suite(.serialized) struct HerdrAccountSelectionTests {
    init() { HerdrWorkOwnership.enable() }
    @Test func namedChoicesAreUniqueAndSelectionSurvivesReloadRemovalAndEmptyState() async throws {
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ClaudeAccountsModel(
            directory: root.appendingPathComponent("accounts"), eraseSecret: { _ in },
            invalidateUsage: {}, refreshUsage: {})
        try await model.load()
        #expect(model.launchSelection("default") == "cli")
        let first = ClaudeAccount(name: "First", credential: "synthetic-first")
        let second = ClaudeAccount(name: "Second", credential: "synthetic-second")
        try await model.persist(.init(accounts: [first, second], defaultID: first.id))
        #expect(model.launchAccounts.map(\.id) == [first.id, second.id])
        #expect(model.launchAccounts.filter { $0.id == first.id }.count == 1)
        #expect(model.launchSelection("default") == first.id.uuidString)
        #expect(model.launchSelection(second.id.uuidString.lowercased()) == second.id.uuidString)
        #expect(model.launchSelection("cli") == "cli")
        #expect(await model.rememberLaunchSelection(second.id.uuidString.lowercased()))
        let restored = ClaudeAccountsModel(directory: try model.directory)
        try await restored.load()
        #expect(restored.launchSelection("default") == second.id.uuidString)
        #expect(restored.launchSelection(first.id.uuidString) == first.id.uuidString)
        #expect(await model.rememberLaunchSelection("cli"))
        #expect(model.state.defaultID == second.id)
        await model.forget(second.id)
        #expect(model.launchSelection(second.id.uuidString) == first.id.uuidString)
        #expect(!(await model.rememberLaunchSelection(second.id.uuidString)))
        #expect(model.error != nil)
        await model.forget(first.id)
        #expect(model.launchAccounts.isEmpty)
        #expect(model.launchSelection("default") == "cli")
    }

    @Test func selectionKeepsForeignEditsAndRefreshesWithoutInvalidatingUsage() async throws {
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let notifications = HerdrSelectionNotifications()
        let model = ClaudeAccountsModel(
            directory: root.appendingPathComponent("accounts"),
            invalidateUsage: { await notifications.invalidate() },
            refreshUsage: { await notifications.refresh() })
        try await model.load()
        let first = ClaudeAccount(name: "First", credential: "synthetic-first")
        let second = ClaudeAccount(name: "Second", credential: "synthetic-second")
        let initial = ClaudeAccountsState(accounts: [first, second], defaultID: first.id)
        try await model.persist(initial)
        var renamed = first
        renamed.name = "Updated first"
        let editor = ClaudeAccountStorage(directory: try model.directory)
        try await editor.save(
            .init(accounts: [renamed, second], defaultID: first.id), expected: initial)
        #expect(await model.rememberLaunchSelection(second.id.uuidString))
        #expect(model.state.accounts == [renamed, second])
        #expect(model.state.defaultID == second.id)
        #expect(try await editor.load() == model.state)
        #expect(await notifications.refreshes == 1)
        #expect(await notifications.invalidations == 0)
    }

    @Test func retainedSelectionTransmitsOnlyCanonicalIdentity() async throws {
        let first = ClaudeAccount(name: "First", credential: "synthetic-private-first")
        let second = ClaudeAccount(name: "Second", credential: "synthetic-private-second")
        var server = ClaudeAccountsState(accounts: [first, second], defaultID: first.id)
        var selections = 0
        let client = HerdrUIClient { operation, payload in
            if operation == "herdr.ui.accounts.read" { return try JSONEncoder().encode(server) }
            #expect(operation == "herdr.ui.accounts.select")
            let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect(Set(object.keys) == ["id"])
            #expect(object["id"] as? String == second.id.uuidString)
            #expect(payload.count <= 128)
            #expect(!String(decoding: payload, as: UTF8.self).contains("synthetic-private"))
            selections += 1
            server.defaultID = second.id
            return try JSONEncoder().encode(server)
        }
        let model = ClaudeAccountsModel(client: client)
        try await model.load()
        #expect(await model.rememberLaunchSelection(second.id.uuidString.lowercased()))
        #expect(model.launchSelection("default") == second.id.uuidString)
        #expect(selections == 1)
        model.shutdown()
    }

    @Test func workerRejectsMalformedIdentityBeforeStorageAndPreservesLatestAccountFields()
        async throws
    {
        defer { HerdrWorkOwnership.enable() }
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("accounts")
        let notifications = HerdrSelectionNotifications()
        let model = ClaudeAccountsModel(
            directory: directory, invalidateUsage: { await notifications.invalidate() },
            refreshUsage: { await notifications.refresh() })
        let worker = HerdrWorker(
            store: HerdrStore(
                defaults: HerdrUIDefaults(), claudeAccounts: model, liveWatcher: { _ in },
                machinesProvider: { [] }),
            defaults: HerdrUIDefaults(), automaticActions: false)
        let invalid: [[String: Any]] = [
            [:], ["id": 42], ["id": "invalid"],
            ["id": UUID().uuidString, "credential": "synthetic-rejected"],
        ]
        for object in invalid {
            await #expect(throws: ExtensionPeerError.self) {
                try await worker.execute(
                    "herdr.ui.accounts.select",
                    payload: JSONSerialization.data(withJSONObject: object))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let first = ClaudeAccount(name: "First", credential: "synthetic-first")
        let second = ClaudeAccount(name: "Second", credential: "synthetic-second")
        let storage = ClaudeAccountStorage(directory: directory)
        let initial = ClaudeAccountsState(accounts: [first, second], defaultID: first.id)
        try await storage.save(initial)
        try await model.load()
        var renamed = first
        renamed.name = "Updated first"
        try await storage.save(
            .init(accounts: [renamed, second], defaultID: first.id), expected: initial)
        let result = try JSONDecoder().decode(
            ClaudeAccountsState.self,
            from: await worker.execute(
                "herdr.ui.accounts.select",
                payload: JSONSerialization.data(withJSONObject: ["id": second.id.uuidString])))
        #expect(result.accounts == [renamed, second])
        #expect(result.defaultID == second.id)
        #expect(await notifications.refreshes == 1)
        #expect(await notifications.invalidations == 0)
        await worker.shutdown()
    }

    @Test func heldSelectionRejectsOverlappingSelectionAndEditsVisibly() async throws {
        let first = ClaudeAccount(name: "First", credential: "synthetic-first")
        let second = ClaudeAccount(name: "Second", credential: "synthetic-second")
        let initial = ClaudeAccountsState(accounts: [first, second], defaultID: first.id)
        var pending: CheckedContinuation<Data, Error>?
        var mutations = 0
        let model = ClaudeAccountsModel(
            client: HerdrUIClient { operation, _ in
                if operation == "herdr.ui.accounts.read" {
                    return try JSONEncoder().encode(initial)
                }
                #expect(operation == "herdr.ui.accounts.select")
                mutations += 1
                return try await withCheckedThrowingContinuation { pending = $0 }
            })
        try await model.load()
        let selected = Task { await model.rememberLaunchSelection(second.id.uuidString) }
        while pending == nil { await Task.yield() }
        #expect(!(await model.rememberLaunchSelection(first.id.uuidString)))
        #expect(model.error != nil)
        #expect(model.launchSelection("default") == first.id.uuidString)
        await model.save(initial)
        #expect(model.error != nil)
        #expect(mutations == 1)
        var updated = first
        updated.name = "Updated first"
        let accepted = ClaudeAccountsState(accounts: [updated, second], defaultID: second.id)
        pending?.resume(returning: try JSONEncoder().encode(accepted))
        #expect(await selected.value)
        #expect(model.state == accepted)
        #expect(model.launchSelection("default") == second.id.uuidString)
        #expect(!model.saving)
        model.shutdown()
    }

    @Test func heldEditorRejectsSelectionThenAllowsAnExplicitRetry() async throws {
        let first = ClaudeAccount(name: "First", credential: "synthetic-first")
        let second = ClaudeAccount(name: "Second", credential: "synthetic-second")
        var server = ClaudeAccountsState(accounts: [first, second], defaultID: first.id)
        var pending: CheckedContinuation<Data, Error>?
        var selections = 0
        let model = ClaudeAccountsModel(
            client: HerdrUIClient { operation, payload in
                if operation == "herdr.ui.accounts.read" { return try JSONEncoder().encode(server) }
                if operation == "herdr.ui.accounts.save" {
                    let mutation = try JSONDecoder().decode(
                        ClaudeAccountsMutation.self, from: payload)
                    #expect(mutation.baseline == server)
                    server = mutation.state
                    return try await withCheckedThrowingContinuation { pending = $0 }
                }
                #expect(operation == "herdr.ui.accounts.select")
                selections += 1
                server.defaultID = second.id
                return try JSONEncoder().encode(server)
            })
        try await model.load()
        var updated = first
        updated.name = "Updated first"
        let edited = ClaudeAccountsState(accounts: [updated, second], defaultID: first.id)
        let edit = Task { await model.save(edited) }
        while pending == nil { await Task.yield() }
        #expect(!(await model.rememberLaunchSelection(second.id.uuidString)))
        #expect(model.error != nil)
        #expect(selections == 0)
        pending?.resume(returning: try JSONEncoder().encode(edited))
        await edit.value
        #expect(await model.rememberLaunchSelection(second.id.uuidString))
        #expect(model.state.accounts == [updated, second])
        #expect(model.state.defaultID == second.id)
        #expect(selections == 1)
        model.shutdown()
    }

    @Test(arguments: ["saved", "imported"])
    func newlySavedOrImportedAccountRemembersItsSelection(source: String) async throws {
        let first = ClaudeAccount(name: "First", credential: "synthetic-first")
        let added = ClaudeAccount(name: "Added", credential: "synthetic-added")
        var server = ClaudeAccountsState(accounts: [first], defaultID: first.id)
        var selections = 0
        let model = ClaudeAccountsModel(
            client: HerdrUIClient { operation, payload in
                switch operation {
                case "herdr.ui.accounts.read": break
                case "herdr.ui.accounts.save":
                    let mutation = try JSONDecoder().decode(
                        ClaudeAccountsMutation.self, from: payload)
                    #expect(mutation.baseline == server)
                    server = mutation.state
                case "herdr.ui.accounts.import":
                    #expect(payload == Data("{}".utf8))
                    server.accounts.append(added)
                    server.defaultID = added.id
                case "herdr.ui.accounts.select":
                    let object = try #require(
                        JSONSerialization.jsonObject(with: payload) as? [String: Any])
                    #expect(Set(object.keys) == ["id"])
                    #expect(object["id"] as? String == added.id.uuidString)
                    selections += 1
                    server.defaultID = added.id
                default: Issue.record("Unexpected account operation")
                }
                return try JSONEncoder().encode(server)
            })
        try await model.load()
        if source == "saved" {
            await model.save(.init(accounts: [first, added], defaultID: first.id))
            #expect(model.error == nil)
        } else {
            #expect(await model.importCurrentCLIAccount()?.id == added.id)
        }
        #expect(await model.rememberLaunchSelection(added.id.uuidString))
        #expect(model.state.defaultID == added.id)
        #expect(model.launchSelection("default") == added.id.uuidString)
        #expect(model.launchAccounts.map(\.id) == [first.id, added.id])
        #expect(selections == 1)
        model.shutdown()
    }

    @Test func heldSelectionCannotApplyReplyAfterShutdown() async throws {
        let first = ClaudeAccount(name: "First", credential: "synthetic-first")
        let second = ClaudeAccount(name: "Second", credential: "synthetic-second")
        let initial = ClaudeAccountsState(accounts: [first, second], defaultID: first.id)
        var pending: CheckedContinuation<Data, Error>?
        let model = ClaudeAccountsModel(
            client: HerdrUIClient { operation, _ in
                if operation == "herdr.ui.accounts.read" {
                    return try JSONEncoder().encode(initial)
                }
                return try await withCheckedThrowingContinuation { pending = $0 }
            })
        try await model.load()
        let selected = Task { await model.rememberLaunchSelection(second.id.uuidString) }
        while pending == nil { await Task.yield() }
        model.shutdown()
        pending?.resume(
            returning: try JSONEncoder().encode(
                ClaudeAccountsState(accounts: [first, second], defaultID: second.id)))
        #expect(!(await selected.value))
        #expect(model.state == initial)
        #expect(!model.ready && !model.saving)
        #expect(model.error == nil)
    }
}
