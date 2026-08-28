import EdithCore
import Testing

@testable import EdithKit

@MainActor
@Suite struct ExtensionReadinessModelTests {
    @Test func firstRefreshPublishesLoadingThenTheReport() async {
        let fixture = ExtensionReadinessFixture()
        let model = ExtensionReadinessModel { await fixture.load($0) }

        let task = model.refresh()

        #expect(model.report == nil)
        #expect(model.isRefreshing)
        await fixture.waitUntilStarted(1)
        await fixture.release(0, report: report("first", phase: .ready))
        await task.value

        #expect(model.report?.state.extensionID == "first")
        #expect(!model.isRefreshing)
    }

    @Test func repeatedRefreshRetainsThePublishedReportUntilReplacementArrives() async {
        let fixture = ExtensionReadinessFixture()
        let model = ExtensionReadinessModel { await fixture.load($0) }

        let first = model.refresh()
        await fixture.waitUntilStarted(1)
        await fixture.release(0, report: report("published", phase: .ready))
        await first.value

        let second = model.refresh(.verify)
        await fixture.waitUntilStarted(2)

        #expect(model.report?.state.extensionID == "published")
        #expect(model.isRefreshing)

        await fixture.release(1, report: report("replacement", phase: .degraded))
        await second.value

        #expect(model.report?.state.extensionID == "replacement")
        #expect(model.report?.state.phase == .degraded)
        #expect(!model.isRefreshing)
    }

    @Test func newestRefreshOwnsPublicationWhenAnOlderLoadFinishesLast() async {
        let fixture = ExtensionReadinessFixture()
        let model = ExtensionReadinessModel { await fixture.load($0) }

        let first = model.refresh()
        await fixture.waitUntilStarted(1)
        let second = model.refresh(.verify)
        await fixture.waitUntilStarted(2)

        #expect(first.isCancelled)
        await fixture.release(1, report: report("new", phase: .ready))
        await second.value
        #expect(model.report?.state.extensionID == "new")
        #expect(!model.isRefreshing)
        #expect(await fixture.requestedOperations() == [.status, .verify])

        await fixture.release(0, report: report("old", phase: .failed))
        await first.value
        #expect(model.report?.state.extensionID == "new")
        #expect(model.report?.state.phase == .ready)
    }

    @Test func cancellationInvalidatesABlockedResult() async {
        let fixture = ExtensionReadinessFixture()
        let model = ExtensionReadinessModel { await fixture.load($0) }

        let task = model.refresh()
        await fixture.waitUntilStarted(1)
        model.cancel()

        #expect(task.isCancelled)
        #expect(!model.isRefreshing)
        await fixture.release(0, report: report("cancelled", phase: .failed))
        await task.value
        #expect(model.report == nil)
    }

    private func report(
        _ id: String, phase: ExtensionLifecyclePhase
    ) -> ExtensionLifecycleReport {
        ExtensionLifecycleReport(
            state: ExtensionLifecycleState(extensionID: id, phase: phase, summary: id), checks: [])
    }
}

private actor ExtensionReadinessFixture {
    private var started = 0
    private var operations: [ExtensionInspectionOperation] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var loadWaiters: [Int: CheckedContinuation<ExtensionLifecycleReport, Never>] = [:]

    func load(_ operation: ExtensionInspectionOperation) async -> ExtensionLifecycleReport {
        operations.append(operation)
        let index = started
        started += 1
        let ready = startWaiters.filter { started >= $0.0 }
        startWaiters.removeAll { started >= $0.0 }
        ready.forEach { $0.1.resume() }
        return await withCheckedContinuation { loadWaiters[index] = $0 }
    }

    func waitUntilStarted(_ count: Int) async {
        guard started < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func release(_ index: Int, report: ExtensionLifecycleReport) {
        loadWaiters.removeValue(forKey: index)?.resume(returning: report)
    }

    func requestedOperations() -> [ExtensionInspectionOperation] {
        operations
    }
}
