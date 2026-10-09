import Foundation
import Observation

@MainActor @Observable
public final class AgentActivityMonitor {
    public static let shared = AgentActivityMonitor()
    public private(set) var now = Date()
    public private(set) var activity = AgentActivitySnapshot()
    public private(set) var terminals: SessionsSnapshot?
    public private(set) var observedAt: [String: Date] = [:]
    public private(set) var load = ContentLoad()
    public private(set) var deciding: Set<UUID> = []
    public private(set) var decisionErrors: [UUID: String] = [:]
    private var observers = 0
    private var feeds: Task<Void, Never>?
    private var feedID = UUID()
    private var terminalFeedID = UUID()
    private var terminalFeed: Task<Void, Never>?
    private let discoversTerminals: @Sendable () -> Bool
    private let client: AgentClient

    public init(
        client: AgentClient = .shared,
        discoversTerminals: @escaping @Sendable () -> Bool = {
            SharedDefaults.store.bool(forKey: AppStorageKeys.Tabs.herdrEnabled)
        }
    ) {
        self.client = client
        self.discoversTerminals = discoversTerminals
    }

    public var presentation: AgentActivityPresentation {
        AgentActivityPresentation(
            activity: activity, terminals: terminals, now: now, observedAt: observedAt)
    }

    public func observe() async {
        observers += 1
        if feeds == nil { startFeeds() }
        defer {
            observers -= 1
            if observers == 0 {
                feeds?.cancel(); feeds = nil
                terminalFeed?.cancel(); terminalFeed = nil
                terminalFeedID = UUID()
                load.cancel()
            }
        }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3600)) } catch { break }
        }
    }

    private func startFeeds() {
        load.begin()
        let id = UUID()
        feedID = id
        let client = client
        syncTerminalFeed()
        feeds = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    do {
                        let snapshot = try await client.snapshotAsync(
                            AgentActivitySnapshot.self, topic: .agentActivity, timeout: 4)
                        await self?.received(snapshot, feedID: id)
                    } catch { await self?.failed(error, feedID: id) }
                    for await value in AgentTopicStream.values(
                        AgentActivitySnapshot.self, topic: .agentActivity, client: client)
                    {
                        guard !Task.isCancelled else { break }
                        await self?.received(value, feedID: id)
                    }
                }
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { break }
                        await self?.tick(feedID: id)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func received(_ snapshot: AgentActivitySnapshot, feedID: UUID) async {
        let active = await Task.detached(priority: .utility) {
            Set(snapshot.approvals.map(\.id))
        }.value
        guard self.feedID == feedID, !Task.isCancelled else { return }
        activity = snapshot
        load.setContent()
        for id in Array(decisionErrors.keys) where !active.contains(id) {
            decisionErrors[id] = nil
        }
    }

    private func failed(_ error: Error, feedID: UUID) {
        guard self.feedID == feedID, !Task.isCancelled else { return }
        load.fail(load.begin(), error: error)
    }

    private func receivedTerminals(_ snapshot: SessionsSnapshot, feedID: UUID) async {
        let active = await Task.detached(priority: .utility) {
            Set(snapshot.hosts.flatMap(\.agents).filter { !$0.isTerminal }.map(\.id))
        }.value
        guard terminalFeedID == feedID, !Task.isCancelled else { return }
        for id in Array(observedAt.keys) where !active.contains(id) { observedAt[id] = nil }
        for id in active where observedAt[id] == nil { observedAt[id] = snapshot.discoveredAt }
        terminals = snapshot
    }

    private func tick(feedID: UUID) {
        guard self.feedID == feedID, !Task.isCancelled else { return }
        now = Date()
        syncTerminalFeed()
    }

    private func syncTerminalFeed() {
        guard discoversTerminals() else {
            terminalFeed?.cancel(); terminalFeed = nil
            terminalFeedID = UUID()
            terminals = nil
            observedAt = [:]
            return
        }
        guard terminalFeed == nil else { return }
        let id = UUID()
        terminalFeedID = id
        let client = client
        terminalFeed = Task { [weak self] in
            for await value in AgentTopicStream.values(
                SessionsSnapshot.self, topic: .sessions, client: client)
            {
                guard !Task.isCancelled else { break }
                await self?.receivedTerminals(value, feedID: id)
            }
        }
    }

    public func retry() {
        feeds?.cancel()
        feeds = nil
        terminalFeed?.cancel(); terminalFeed = nil
        terminalFeedID = UUID()
        client.reset()
        if observers > 0 { startFeeds() }
    }

    public func decide(_ request: AgentApprovalRequest, choice: AgentApprovalChoice) async {
        guard deciding.insert(request.id).inserted else { return }
        defer { deciding.remove(request.id) }
        do {
            let payload = try AgentPayload.encode(
                AgentApprovalDecision(token: AgentApprovalToken(request), choice: choice))
            let response = try await client.performInternalAsync(
                AgentActivityOperation.decide, payload: payload)
            guard try AgentPayload.decode(Bool.self, from: response) else {
                throw AgentError(
                    .refused,
                    "This request was already answered, expired, or is no longer available.")
            }
            decisionErrors[request.id] = nil
        } catch { decisionErrors[request.id] = error.localizedDescription }
    }
}
