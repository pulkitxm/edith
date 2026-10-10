import DatabaseEngine
import Testing
@testable import DatabaseExtension

@MainActor @Suite struct DatabasePageModelTests {
    @Test func readinessSucceeds() async {
        let model = DatabasePageModel(ensureReady: {})
        await model.refresh()
        #expect(model.readiness == .ready)
        #expect(model.failureDetail == nil)
    }

    @Test func stoppedEngineCanBeRetried() async {
        let calls = DatabasePageCallRecorder()
        let model = DatabasePageModel(
            ensureReady: { throw DatabaseEngineError.stopped },
            repairService: { await calls.recordRepair() })
        await model.refresh()
        #expect(model.failureDetail != nil)
        await model.repair()
        #expect(model.readiness == .ready)
        #expect(await calls.repairCount == 1)
    }

    @Test func cancelledReadinessIsRecoverable() async {
        let model = DatabasePageModel(ensureReady: { throw CancellationError() })
        await model.refresh()
        #expect(model.readiness == .failed("The database readiness check was cancelled."))
    }
}

private actor DatabasePageCallRecorder {
    private(set) var repairCount = 0
    func recordRepair() { repairCount += 1 }
}
