import EdithKit
import SwiftUI

private struct AgentTopicModifier<Value: Decodable & Sendable>: ViewModifier {
    let topic: AgentTopic
    let active: Bool
    let perform: @MainActor (Value) -> Void
    @Environment(\.windowVisible) private var windowVisible

    func body(content: Content) -> some View {
        content.task(id: active && windowVisible) {
            guard active, windowVisible else { return }
            for await value in AgentTopicStream.values(Value.self, topic: topic) {
                guard !Task.isCancelled else { return }
                await MainActor.run { perform(value) }
            }
        }
    }
}

extension View {
    func agentTopic<Value: Decodable & Sendable>(
        _ topic: AgentTopic, as type: Value.Type = Value.self, active: Bool = true,
        perform: @escaping @MainActor (Value) -> Void
    ) -> some View {
        modifier(AgentTopicModifier(topic: topic, active: active, perform: perform))
    }
}
