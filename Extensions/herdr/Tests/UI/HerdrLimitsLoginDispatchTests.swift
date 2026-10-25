import Darwin
import EdithExtensionAccounts
import EdithExtensionSupport
import Foundation
import Testing
@testable import HerdrUI

@Suite(.serialized) @MainActor struct HerdrLimitsLoginDispatchTests {
    @Test func independentCancellationBeforeCanonicalLoadReturnsPreventsLateLogin() async throws {
        HerdrWorkOwnership.enable()
        defer { HerdrWorkOwnership.enable() }
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = HerdrLimitsTerminalFixture()
        var creations = 0
        let owner = HerdrLimitsLogin(
            services: .init(
                create: { _ in
                    creations += 1
                    return terminal
                }, eraseScopedSecret: { _ in }))
        let gate = HerdrLimitsReplyGate()
        let directory = root.appendingPathComponent("Accounts")
        let model = ClaudeAccountsModel(
            directory: directory, limitsLogin: owner,
            readState: { storage in
                await gate.hold()
                return try await storage.load()
            }, eraseSecret: { _ in }, invalidateUsage: {}, refreshUsage: {})
        let account = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-launch-secret")
        let original = ClaudeAccountsState(accounts: [account])
        try await model.persist(original)
        let defaults = HerdrUIDefaults()
        let store = HerdrStore(
            defaults: defaults, claudeAccounts: model, liveWatcher: { _ in },
            machinesProvider: { [] })
        let worker = HerdrWorker(
            store: store, defaults: defaults, trackingDemand: { false }, searchDecider: { nil },
            automaticActions: false)
        let ticket = UUID()
        let control = try JSONSerialization.data(withJSONObject: [
            "id": account.id.uuidString, "ticket": ticket.uuidString,
        ])
        let foreign = try JSONSerialization.data(withJSONObject: [
            "id": account.id.uuidString, "ticket": UUID().uuidString,
        ])
        let start = Task {
            try await worker.execute("herdr.ui.accounts.limitsStart", payload: control)
        }
        await gate.waitUntilHeld()
        let cancellationResult = HerdrLimitsCancellationResult()
        var cancellation: Task<Void, Error>?
        do {
            let waitingData = try await worker.execute(
                "herdr.ui.accounts.limitsStatus", payload: control)
            let waiting = try JSONDecoder().decode(HerdrLimitsLoginState.self, from: waitingData)
            #expect(waiting.accountID == account.id && waiting.ticket == ticket)
            #expect(waiting.phase == .connecting && waiting.session == nil)
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await worker.execute("herdr.ui.accounts.limitsCancel", payload: foreign)
            }
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await worker.execute("herdr.ui.accounts.limitsStart", payload: foreign)
            }
            let cancelledData = try await worker.execute(
                "herdr.ui.accounts.limitsCancel", payload: control)
            let cancelled = try JSONDecoder().decode(
                HerdrLimitsLoginState.self, from: cancelledData)
            #expect(cancelled.phase == .connecting && cancelled.session == nil)
            #expect(!start.isCancelled && creations == 0 && terminal.closeCalls == 0)
            let heldData = try await worker.execute(
                "herdr.ui.accounts.limitsStatus", payload: control)
            let held = try JSONDecoder().decode(HerdrLimitsLoginState.self, from: heldData)
            #expect(held.phase == .connecting)
            cancellation = Task {
                cancellationResult.entered = true
                let result = try await owner.cancel(accountID: account.id, ticket: ticket)
                #expect(result.phase == .cancelled && result.session == nil)
                cancellationResult.returned = true
            }
            let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !cancellationResult.entered {
                try #require(ContinuousClock.now < cancellationDeadline)
                await Task.yield()
            }
            #expect(!cancellationResult.returned)
            gate.release()
            await #expect(throws: (any Error).self) { _ = try await start.value }
            let joinedCancellation = try #require(cancellation)
            try await joinedCancellation.value
            #expect(cancellationResult.returned)
            await owner.joinPendingWork()
            let finishedData = try await worker.execute(
                "herdr.ui.accounts.limitsStatus", payload: control)
            let finished = try JSONDecoder().decode(HerdrLimitsLoginState.self, from: finishedData)
            #expect(finished.phase == .cancelled && finished.session == nil)
            #expect(!owner.hasPendingWork)
            #expect(creations == 0 && terminal.closeCalls == 0)
            let saved = try await ClaudeAccountStorage(directory: directory).load()
            #expect(saved == original)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(!names.contains("limits-cleanup.json") && !names.contains(".limits-start.lock"))
            #expect(!names.contains(where: { UUID(uuidString: $0) != nil }))
            await worker.shutdown()
        } catch {
            gate.release()
            terminal.releaseClose()
            start.cancel()
            cancellation?.cancel()
            _ = try? await start.value
            _ = try? await cancellation?.value
            await worker.shutdown()
            throw error
        }
    }

    @Test func workerCancellationRejectsStartAfterHeldCanonicalLoadResumes() async throws {
        HerdrWorkOwnership.enable()
        defer { HerdrWorkOwnership.enable() }
        let temporary = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        let physical = try #require(realpath(temporary, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = HerdrLimitsTerminalFixture()
        var creations = 0
        let owner = HerdrLimitsLogin(
            services: .init(
                create: { _ in
                    creations += 1; return terminal
                }, eraseScopedSecret: { _ in }))
        let gate = HerdrLimitsReplyGate()
        let directory = root.appendingPathComponent("Accounts")
        let model = ClaudeAccountsModel(
            directory: directory, limitsLogin: owner,
            readState: { storage in
                await gate.hold()
                return try await storage.load()
            }, eraseSecret: { _ in }, invalidateUsage: {}, refreshUsage: {})
        let account = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-launch-secret")
        let original = ClaudeAccountsState(accounts: [account])
        try await model.persist(original)
        let defaults = HerdrUIDefaults()
        let store = HerdrStore(
            defaults: defaults, claudeAccounts: model, liveWatcher: { _ in },
            machinesProvider: { [] })
        let worker = HerdrWorker(
            store: store, defaults: defaults, trackingDemand: { false }, searchDecider: { nil },
            automaticActions: false)
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": account.id.uuidString, "ticket": UUID().uuidString,
        ])
        let start = Task {
            try await worker.execute("herdr.ui.accounts.limitsStart", payload: payload)
        }
        await gate.waitUntilHeld()
        do {
            worker.requestWorkCancellation()
            #expect(throws: ExtensionPeerError.self) {
                _ = try owner.begin(
                    account: account, ticket: UUID(),
                    storage: ClaudeAccountStorage(directory: directory), command: "cc",
                    sharedEnvironment: "", inheritedEnvironment: [:])
            }
            #expect(creations == 0)
            gate.release()
            await #expect(throws: ExtensionPeerError.self) { _ = try await start.value }
            #expect(model.state == original)
            #expect(creations == 0 && terminal.closeCalls == 0)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(!names.contains("limits-cleanup.json") && !names.contains(".limits-start.lock"))
            #expect(!names.contains(where: { UUID(uuidString: $0) != nil }))
            terminal.releaseClose()
            await worker.shutdown()
        } catch {
            gate.release()
            terminal.releaseClose()
            start.cancel()
            _ = try? await start.value
            await worker.shutdown()
            throw error
        }
    }

    @Test(arguments: ["lost", "before", "alteredAccount", "alteredTicket"])
    func lostOrAlteredReplyAndCancelledBeforeDispatchRetainOwnedCleanup(kind: String)
        async throws
    {
        HerdrWorkOwnership.enable()
        defer { HerdrWorkOwnership.enable() }
        let temporary = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        let physical = try #require(realpath(temporary, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = HerdrLimitsTerminalFixture()
        var creations = 0
        let owner = HerdrLimitsLogin(
            services: .init(
                create: { _ in
                    creations += 1; return terminal
                }, eraseScopedSecret: { _ in }))
        let backend = ClaudeAccountsModel(
            directory: root.appendingPathComponent("Accounts"), limitsLogin: owner,
            eraseSecret: { _ in }, invalidateUsage: {}, refreshUsage: {})
        try await backend.load()
        let account = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-launch-secret")
        let original = ClaudeAccountsState(accounts: [account])
        try await backend.persist(original)
        let defaults = HerdrUIDefaults()
        let store = HerdrStore(
            defaults: defaults, claudeAccounts: backend, liveWatcher: { _ in },
            machinesProvider: { [] })
        let worker = HerdrWorker(
            store: store, defaults: defaults, trackingDemand: { false }, searchDecider: { nil },
            automaticActions: false)
        let gate = HerdrLimitsReplyGate()
        let beforeDispatch = kind == "before"
        let alteredTicket = UUID()
        var cancelledTickets: [UUID] = []
        let client = HerdrUIClient { operation, payload in
            if operation == "herdr.ui.accounts.limitsStart" {
                if beforeDispatch {
                    await gate.hold()
                    return try await worker.execute(operation, payload: payload)
                }
                let reply = try await worker.execute(operation, payload: payload)
                await gate.hold()
                if kind.hasPrefix("altered") {
                    let original = try JSONDecoder().decode(HerdrLimitsLoginState.self, from: reply)
                    return try JSONEncoder().encode(
                        HerdrLimitsLoginState(
                            accountID: kind == "alteredAccount" ? UUID() : original.accountID,
                            ticket: kind == "alteredTicket" ? alteredTicket : original.ticket,
                            session: original.session,
                            phase: original.phase))
                }
                return reply
            }
            if operation == "herdr.ui.accounts.limitsCancel" {
                let object = try #require(
                    JSONSerialization.jsonObject(with: payload) as? [String: String])
                let ticketString = try #require(object["ticket"])
                let ticket = UUID(uuidString: ticketString)
                cancelledTickets.append(try #require(ticket))
            }
            return try await worker.execute(operation, payload: payload)
        }
        let frontend = ClaudeAccountsModel(client: client)
        let presentation = frontend.subscriptionLogin
        do {
            try await frontend.load()
            presentation.start(accountID: account.id, accounts: frontend, defaults: defaults)
            await gate.waitUntilHeld()
            let provisional = try #require(presentation.state)
            #expect(provisional.accountID == account.id)
            if !beforeDispatch { await terminal.waitUntilExitHeld() }
            if !kind.hasPrefix("altered") { presentation.cancel() }
            gate.release()
            if !beforeDispatch {
                await terminal.waitUntilCloseHeld()
                #expect(presentation.running)
                #expect(
                    try owner.status(accountID: account.id, ticket: provisional.ticket).phase
                        == .connecting)
                terminal.releaseClose()
            }
            await presentation.stopAndWait()
            #expect(!presentation.running)
            #expect(creations == (beforeDispatch ? 0 : 1))
            #expect(terminal.closeCalls == (beforeDispatch ? 0 : 1))
            #expect(cancelledTickets == [provisional.ticket])
            #expect(!cancelledTickets.contains(alteredTicket))
            #expect(backend.state == original)
            if beforeDispatch {
                #expect(throws: ExtensionPeerError.self) {
                    _ = try owner.status(accountID: account.id, ticket: provisional.ticket)
                }
            } else {
                #expect(presentation.state?.phase == .cancelled)
                #expect(
                    try owner.status(accountID: account.id, ticket: provisional.ticket).phase
                        == .cancelled)
            }
            client.stop()
            await worker.shutdown()
        } catch {
            gate.release()
            terminal.releaseClose()
            await presentation.stopAndWait()
            client.stop()
            await worker.shutdown()
            throw error
        }
    }

    @Test func actualDispatcherCancelsWithoutWaitingAndKeepsStatusAvailableDuringForget()
        async throws
    {
        HerdrWorkOwnership.enable()
        defer { HerdrWorkOwnership.enable() }
        let temporary = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        let physical = try #require(realpath(temporary, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = HerdrLimitsTerminalFixture()
        let owner = HerdrLimitsLogin(
            services: .init(create: { _ in terminal }, eraseScopedSecret: { _ in }))
        let model = ClaudeAccountsModel(
            directory: root.appendingPathComponent("Accounts"), limitsLogin: owner,
            eraseSecret: { _ in }, invalidateUsage: {}, refreshUsage: {})
        try await model.load()
        let account = ClaudeAccount(name: "Synthetic launch", credential: "synthetic-launch-secret")
        try await model.persist(.init(accounts: [account]))
        let defaults = HerdrUIDefaults()
        let store = HerdrStore(
            defaults: defaults, claudeAccounts: model, liveWatcher: { _ in },
            machinesProvider: { [] })
        let worker = HerdrWorker(
            store: store, defaults: defaults, trackingDemand: { false }, searchDecider: { nil },
            automaticActions: false)
        var forget: Task<Data, Error>?
        do {
            let identityPayload = try JSONSerialization.data(withJSONObject: [
                "id": account.id.uuidString
            ])
            let startPayload = try JSONSerialization.data(withJSONObject: [
                "id": account.id.uuidString, "ticket": UUID().uuidString,
            ])
            let data = try await worker.execute(
                "herdr.ui.accounts.limitsStart", payload: startPayload)
            let state = try JSONDecoder().decode(HerdrLimitsLoginState.self, from: data)
            #expect(state.accountID == account.id && state.phase == .connecting)
            await terminal.waitUntilExitHeld()
            let control = try JSONSerialization.data(withJSONObject: [
                "id": account.id.uuidString, "ticket": state.ticket.uuidString,
            ])
            let cancellation = try await worker.execute(
                "herdr.ui.accounts.limitsCancel", payload: control)
            #expect(
                try JSONDecoder().decode(HerdrLimitsLoginState.self, from: cancellation).phase
                    == .connecting)
            await terminal.waitUntilCloseHeld()
            forget = Task {
                try await worker.execute("herdr.ui.accounts.forget", payload: identityPayload)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !model.saving {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(1))
            }
            let status = try await worker.execute(
                "herdr.ui.accounts.limitsStatus", payload: control)
            let waiting = try JSONDecoder().decode(HerdrLimitsLoginState.self, from: status)
            #expect(waiting.phase == .connecting && waiting.session == terminal.handle)
            #expect(model.saving)
            let foreign = try JSONSerialization.data(withJSONObject: [
                "id": account.id.uuidString, "ticket": UUID().uuidString,
            ])
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await worker.execute("herdr.ui.accounts.limitsCancel", payload: foreign)
            }
            #expect(terminal.closeCalls == 1)
            terminal.releaseClose()
            let forgotten = try #require(forget)
            let result = try JSONDecoder().decode(
                ClaudeAccountsState.self, from: await forgotten.value)
            #expect(result.accounts.isEmpty)
            let finished = try await worker.execute(
                "herdr.ui.accounts.limitsStatus", payload: control)
            let closed = try JSONDecoder().decode(HerdrLimitsLoginState.self, from: finished)
            #expect(closed.phase == .cancelled && closed.session == nil)
            #expect(!String(decoding: finished, as: UTF8.self).contains(account.credential))
            await worker.shutdown()
        } catch {
            terminal.releaseClose()
            forget?.cancel()
            await worker.shutdown()
            _ = try? await forget?.value
            throw error
        }
    }
}

@MainActor private final class HerdrLimitsCancellationResult {
    var entered = false
    var returned = false
}

@MainActor private final class HerdrLimitsReplyGate {
    private var held = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        held = true
        waiting?.resume()
        waiting = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
