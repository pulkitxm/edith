import Foundation
import Testing

@testable import EdithKit

@Suite struct AgentClientTransportTests {
    private let operation = AgentControlOperation.status.descriptor.id

    @Test func racingRepliesResolveExactlyOnce() {
        let reply = AgentReply<Int>()
        let observed = TransportValues<Int>()
        reply.observe { if case .success(let value) = $0 { observed.append(value) } }
        DispatchQueue.concurrentPerform(iterations: 200) { reply.finish(.success($0)) }
        #expect(observed.values.count == 1)
        #expect(reply.completedValue == observed.values.first)
    }

    @Test @MainActor func asynchronousRequestsYieldTheMainActor() async throws {
        let fixture = TransportFixture()
        let client = fixture.client()
        try await client.verifyHandshakeAsync()
        fixture.latest.delay = 0.05
        let ticks = TransportValues<Int>()
        fixture.latest.producePayload = { Data(ticks.values.isEmpty ? "false".utf8 : "true".utf8) }
        let heartbeat = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(5))
            ticks.append(1)
        }
        #expect(try await client.performAsync(Bool.self, operation: operation))
        try await heartbeat.value
    }

    @Test func longRequestsUseTheirOwnDeadline() async throws {
        let fixture = TransportFixture()
        let client = fixture.client()
        try await client.verifyHandshakeAsync()
        fixture.latest.delay = AgentClient.replyTimeout + 0.1
        let response = try await client.performAsync(operation, timeout: 6)
        #expect(response == Data("true".utf8))
        #expect(!client.isCoolingDown)
    }

    @Test func timeoutDoesNotPoisonAHealthyConnectionOrAcceptLateReplies() async throws {
        let fixture = TransportFixture()
        let client = fixture.client()
        try await client.verifyHandshakeAsync()
        fixture.latest.delay = 0.04
        await #expect(throws: AgentError.self) {
            _ = try await client.performAsync(operation, timeout: 0.005)
        }
        #expect(!client.isCoolingDown)
        fixture.latest.delay = 0
        #expect(try await client.performAsync(operation) == Data("true".utf8))
        try await Task.sleep(for: .milliseconds(60))
        #expect(fixture.connections.count == 1)
    }

    @Test func cancellationStopsWaitingAndAllowsTheDaemonToFinish() async throws {
        let fixture = TransportFixture()
        let client = fixture.client()
        try await client.verifyHandshakeAsync()
        fixture.latest.delay = 0.08
        let request = Task { try await client.performAsync(operation, timeout: 10) }
        try await wait { fixture.latest.performCount > 0 }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        fixture.latest.delay = 0
        #expect(try await client.performAsync(operation) == Data("true".utf8))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!client.isCoolingDown)
    }

    @Test func proxyErrorsReturnImmediately() async throws {
        let fixture = TransportFixture()
        let client = fixture.client()
        try await client.verifyHandshakeAsync()
        fixture.latest.proxyFails = true
        let started = ContinuousClock.now
        await #expect(throws: AgentError.self) { _ = try await client.performAsync(operation) }
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test func remoteFailuresAndMalformedResponsesDoNotBreakTheConnection() async throws {
        let fixture = TransportFixture()
        let client = fixture.client()
        try await client.verifyHandshakeAsync()
        fixture.latest.operationFailure = "Fixture operation failed."
        await #expect(throws: AgentError.self) { _ = try await client.performAsync(operation) }
        fixture.latest.operationFailure = nil
        await #expect(throws: DecodingError.self) {
            _ = try await client.performAsync([String].self, operation: operation)
        }
        #expect(try await client.performAsync(Bool.self, operation: operation))
        #expect(fixture.connections.count == 1)
    }

    @Test func failedSubscriptionsRollBackTheirLocalHandlers() async throws {
        let fixture = TransportFixture()
        let client = fixture.client()
        try await client.verifyHandshakeAsync()
        fixture.latest.subscriptionFailure = "Fixture topic refused."
        let received = TransportValues<Data>()
        await #expect(throws: AgentError.self) {
            _ = try await client.subscribeAsync(.usage) { received.append($0) }
        }
        fixture.latest.emit("usage", Data("true".utf8))
        #expect(received.values.isEmpty)
        fixture.latest.disconnect()
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.connections.count == 1)
    }

    @Test func reconnectRestoresTopicsAndBusChannels() async throws {
        let fixture = TransportFixture()
        let client = fixture.client()
        let topics = TransportValues<Data>()
        let messages = TransportValues<String>()
        let topic = try await client.subscribeAsync(.usage) { topics.append($0) }
        let bus = try await client.subscribeBusAsync(channel: "test") {
            if let value = $0["value"] as? String { messages.append(value) }
        }
        let previous = fixture.latest
        previous.disconnect()
        try await wait {
            fixture.connections.count == 2
                && fixture.latest.topics.contains("usage")
                && fixture.latest.channels.contains("test")
        }
        previous.emit("usage", Data("0".utf8))
        fixture.latest.emit("usage", Data("42".utf8))
        fixture.latest.emit("bus:test", Data(#"{"value":"restored"}"#.utf8))
        #expect(topics.values == [Data("42".utf8)])
        #expect(messages.values == ["restored"])
        topic.cancel()
        bus.cancel()
        try await wait { fixture.latest.topics.isEmpty && fixture.latest.channels.isEmpty }
    }

    @Test func onlyTheLastSubscriberUnsubscribesAndCancellationIsIdempotent() async throws {
        let fixture = TransportFixture()
        let client = fixture.client()
        let first = try await client.subscribeAsync(.usage) { _ in }
        let second = try await client.subscribeAsync(.usage) { _ in }
        first.cancel()
        #expect(fixture.latest.topics.contains("usage"))
        second.cancel()
        second.cancel()
        try await wait { fixture.latest.unsubscribeCount == 1 }
    }

    @Test func topicStreamsKeepOnlyTheNewestUnreadSnapshot() async throws {
        let fixture = TransportFixture()
        let client = fixture.client()
        let stream = AgentTopicStream.values(Int.self, topic: .usage, client: client)
        try await wait { fixture.connections.last?.topics.contains("usage") == true }
        for value in 0..<10_000 { fixture.latest.emit("usage", Data("\(value)".utf8)) }
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 9_999)
    }

    @Test func aTopicStreamRecoversWhenTheDaemonWasUnavailableAtCreation() async throws {
        let fixture = TransportFixture(firstConnectionFails: true)
        let client = fixture.client()
        let stream = AgentTopicStream.values(Int.self, topic: .usage, client: client)
        try await wait {
            fixture.connections.count >= 2 && fixture.latest.topics.contains("usage")
        }
        fixture.latest.emit("usage", Data("7".utf8))
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 7)
    }

    @Test func synchronousRequestsShareRaceSafeReplyHandling() throws {
        let fixture = TransportFixture()
        let client = fixture.client()
        #expect(try client.perform(operation) == Data("true".utf8))
        let subscription = try client.subscribe(.usage) { _ in }
        subscription.cancel()
    }

    private func wait(_ ready: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(ready())
    }
}

private final class TransportValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}

private final class TransportFixture: @unchecked Sendable {
    private let stored = TransportValues<TransportConnection>()
    private let firstConnectionFails: Bool

    init(firstConnectionFails: Bool = false) { self.firstConnectionFails = firstConnectionFails }

    var connections: [TransportConnection] { stored.values }
    var latest: TransportConnection { connections.last! }

    func client() -> AgentClient {
        AgentClient(
            connectionFactory: { [self] disconnected, received in
                let connection = TransportConnection(disconnected: disconnected, received: received)
                if connections.isEmpty, firstConnectionFails { connection.proxyFails = true }
                stored.append(connection)
                return connection
            }, reconnectDelay: 0.005)
    }
}

private final class TransportConnection: NSObject, AgentClientConnection, EdithAgentXPC,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let disconnected: @Sendable () -> Void
    private let received: @Sendable (String, Data) -> Void
    private var registeredTopics = Set<String>()
    private var registeredChannels = Set<String>()
    private var performed = 0
    private var unsubscribed = 0
    private var replyDelay: TimeInterval = 0
    private var proxyFailure = false
    private var operationError: String?
    private var subscriptionError: String?
    private var payload: @Sendable () -> Data = { Data("true".utf8) }

    init(
        disconnected: @escaping @Sendable () -> Void,
        received: @escaping @Sendable (String, Data) -> Void
    ) {
        self.disconnected = disconnected
        self.received = received
    }

    var producePayload: @Sendable () -> Data {
        get { lock.withLock { payload } }
        set { lock.withLock { payload = newValue } }
    }

    var topics: Set<String> { lock.withLock { registeredTopics } }
    var channels: Set<String> { lock.withLock { registeredChannels } }
    var performCount: Int { lock.withLock { performed } }
    var unsubscribeCount: Int { lock.withLock { unsubscribed } }
    var delay: TimeInterval {
        get { lock.withLock { replyDelay } }
        set { lock.withLock { replyDelay = newValue } }
    }
    var proxyFails: Bool {
        get { lock.withLock { proxyFailure } }
        set { lock.withLock { proxyFailure = newValue } }
    }
    var operationFailure: String? {
        get { lock.withLock { operationError } }
        set { lock.withLock { operationError = newValue } }
    }
    var subscriptionFailure: String? {
        get { lock.withLock { subscriptionError } }
        set { lock.withLock { subscriptionError = newValue } }
    }

    func remote(onError: @escaping @Sendable (Error) -> Void) throws -> EdithAgentXPC {
        if proxyFails { onError(AgentError.unavailable) }
        return self
    }

    func invalidate() {}
    func disconnect() { disconnected() }
    func emit(_ topic: String, _ payload: Data) { received(topic, payload) }

    func handshake(peerVersion: Int, reply: @escaping (Data?, String?) -> Void) {
        reply(
            try? AgentPayload.encode(
                AgentHandshake(protocolVersion: peerVersion, build: "test", startedAt: Date())), nil
        )
    }

    func snapshot(topic: String, reply: @escaping (Data?, String?) -> Void) {
        respond(reply)
    }

    func subscribe(topic: String, reply: @escaping (String?) -> Void) {
        let failure = subscriptionFailure
        if failure == nil { _ = lock.withLock { registeredTopics.insert(topic) } }
        reply(failure)
    }

    func unsubscribe(topic: String, reply: @escaping (String?) -> Void) {
        lock.withLock {
            registeredTopics.remove(topic)
            unsubscribed += 1
        }
        reply(nil)
    }

    func perform(operation: String, payload: Data, reply: @escaping (Data?, String?) -> Void) {
        lock.withLock { performed += 1 }
        if operation == AgentBus.subscribe || operation == AgentBus.unsubscribe,
            let message = try? AgentPayload.decode(AgentBusMessage.self, from: payload)
        {
            lock.withLock {
                if operation == AgentBus.subscribe {
                    registeredChannels.insert(message.channel)
                } else {
                    registeredChannels.remove(message.channel)
                }
            }
            reply(Data(), nil)
            return
        }
        respond(reply)
    }

    private func respond(_ reply: @escaping (Data?, String?) -> Void) {
        let failure = operationFailure
        let delay = delay
        let payload = producePayload
        if delay == 0 {
            reply(failure == nil ? payload() : nil, failure)
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                reply(failure == nil ? payload() : nil, failure)
            }
        }
    }
}
