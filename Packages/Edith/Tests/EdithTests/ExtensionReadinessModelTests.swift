import EdithCore
import Testing

@testable import EdithKit

@MainActor
@Suite struct ExtensionReadinessModelTests {
    @Test func newestRefreshOwnsPublicationWhenAnOlderLoadFinishesLast() async {
        let fixture = ExtensionReadinessFixture()
        let model = ExtensionReadinessModel { await fixture.load() }

        let first = model.refresh()
        await fixture.waitUntilStarted(1)
        let second = model.refresh()
        await fixture.waitUntilStarted(2)

        #expect(first.isCancelled)
        await fixture.release(1, report: report("new", phase: .ready))
        await second.value
        #expect(model.report?.state.extensionID == "new")
        #expect(!model.isRefreshing)

        await fixture.release(0, report: report("old", phase: .failed))
        await first.value
        #expect(model.report?.state.extensionID == "new")
        #expect(model.report?.state.phase == .ready)
    }

    @Test func cancellationInvalidatesABlockedResult() async {
        let fixture = ExtensionReadinessFixture()
        let model = ExtensionReadinessModel { await fixture.load() }

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
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var loadWaiters: [Int: CheckedContinuation<ExtensionLifecycleReport, Never>] = [:]

    func load() async -> ExtensionLifecycleReport {
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
}
