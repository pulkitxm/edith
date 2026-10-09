import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class PresenterState {
    static let shared = PresenterState()
    private var state: SurfacePrivacyState?
    var active: Bool { state?.values["active"] == "1" }
    var hidesAgents: Bool { SurfacePrivacyState.hides(.agents, values: state?.values ?? [:]) }
    func start() {
        guard state == nil, let channel = ExtensionSharedState.current else { return }
        state = SurfacePrivacyState(channel: channel)
    }
    func shutdown() { state?.shutdown(); state = nil }
}

struct AgentTerminalAttentionObservation: Codable, Equatable, Sendable {
    var state: HerdrAttentionState
    var checkedAt: Date
}
struct SessionsSnapshot: Codable, Equatable, Sendable {
    var discoveredAt: Date
    var hosts: [HerdrHostSnapshot]
    var working: Int
    var total: Int
    var attention: [String: AgentTerminalAttentionObservation] = [:]
}

enum HerdrTopic { case sessions, hooks }
private struct HerdrTopicModifier<Value: Decodable & Sendable>: ViewModifier {
    let topic: HerdrTopic
    let active: Bool
    let perform: @MainActor (Value) -> Void
    func body(content: Content) -> some View {
        content.task(id: active) {
            guard active else { return }
            for await data in HerdrTopicFeed.values(topic) {
                guard !Task.isCancelled else { return }
                if let value = try? AgentPayload.decode(Value.self, from: data) {
                    await MainActor.run { perform(value) }
                }
            }
        }
    }
}
extension View {
    func agentTopic<Value: Decodable & Sendable>(
        _ topic: HerdrTopic, as type: Value.Type = Value.self, active: Bool = true,
        perform: @escaping @MainActor (Value) -> Void
    ) -> some View {
        modifier(HerdrTopicModifier(topic: topic, active: active, perform: perform))
    }
}
enum HerdrTopicFeed {
    private static let lock = NSLock()
    private static var listeners: [UUID: (HerdrTopic, AsyncStream<Data>.Continuation)] = [:]
    static func values(_ topic: HerdrTopic) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock { listeners[id] = (topic, continuation) }
            continuation.onTermination = { _ in
                _ = lock.withLock { listeners.removeValue(forKey: id) }
            }
        }
    }
    static func publish(_ topic: HerdrTopic, data: Data) {
        let selected = lock.withLock { listeners.values.filter { $0.0 == topic }.map { $0.1 } }
        for listener in selected { listener.yield(data) }
    }
    static func shutdown() {
        let current = lock.withLock {
            let values = Array(listeners.values); listeners.removeAll(); return values
        }
        for (_, listener) in current { listener.finish() }
    }
}

struct AgentJevDecider: JevDeciding {
    let endpoint: ExtensionPeerEndpoint
    static func configured() -> Self? {
        ExtensionPeerEndpoint.current(owner: "jev").map { Self(endpoint: $0) }
    }
    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
        struct Call: Encodable { let purpose: String; let request: JevRequest }
        struct Reply: Decodable { let decision: JevDecision?; let error: JevError? }
        let data = try await endpoint.invoke(
            "jev.decide", payload: AgentPayload.encode(Call(purpose: purpose, request: request)),
            timeout: 12)
        let reply = try AgentPayload.decode(Reply.self, from: data)
        guard let decision = reply.decision else { throw reply.error ?? JevError.malformedResponse }
        return decision
    }
}

private struct TerminalLaunchEnabledKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var terminalLaunchEnabled: Bool {
        get { self[TerminalLaunchEnabledKey.self] }
        set { self[TerminalLaunchEnabledKey.self] = newValue }
    }
}
