import EdithKit
import Foundation
import Testing

@testable import Edith

@MainActor
@Suite struct AgentEventsModelTests {
    @Test func boundsRetentionAndPagesNewestFirst() {
        let model = AgentEventsModel()
        let events = (0..<700).map {
            AgentEvent(category: "job", name: "run.\($0)", message: "Finished sample job")
        }
        model.receive(events)
        #expect(!model.loading)
        #expect(model.events.count == AgentDiagnostics.capacity)
        #expect(model.visibleEvents.count == 50)
        #expect(model.visibleEvents.first?.id == events.last?.id)
        model.loadMore()
        #expect(model.visibleEvents.count == 100)
        for _ in 0..<20 { model.loadMore() }
        #expect(model.visibleEvents.count == AgentDiagnostics.capacity)
        #expect(!model.hasMore)
    }

    @Test func filtersAcrossUnloadedPagesAndResetsPagination() {
        let model = AgentEventsModel()
        let task = UUID()
        let events =
            [
                AgentEvent(
                    level: .error, category: "backup", name: "failed", message: "Sample failure",
                    taskID: task),
                AgentEvent(
                    level: .warning, category: "backup", name: "deferred", message: "Sample warning"
                ),
            ]
            + (0..<100).map {
                AgentEvent(category: "job", name: "run.\($0)", message: "Sample success")
            }
        model.receive(events)
        model.loadMore()
        model.filter(search: " BACKUP ", errorsOnly: true)
        #expect(model.visibleCount == AgentEventsModel.pageSize)
        #expect(model.matches.map(\.name) == ["deferred", "failed"])
        model.filter(search: task.uuidString.lowercased(), errorsOnly: false)
        #expect(model.matches.map(\.name) == ["failed"])
        model.filter(search: "missing", errorsOnly: false)
        #expect(model.matches.isEmpty)
    }

    @Test func liveUpdatesKeepActiveFilterAndPageDepth() {
        let model = AgentEventsModel()
        model.filter(search: "failure", errorsOnly: true)
        model.receive([
            AgentEvent(level: .error, category: "job", name: "failed", message: "Sample failure")
        ])
        #expect(model.matches.count == 1)
        model.receive([AgentEvent(category: "job", name: "success", message: "Sample success")])
        #expect(model.matches.isEmpty)
        #expect(!model.loading)
    }
}
