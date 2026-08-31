import EdithDatabase
import Testing

@testable import Edith

@MainActor
@Suite("Database page readiness")
struct DatabasePageModelTests {
    @Test("Initial readiness succeeds without exposing service status")
    func initialReadiness() async {
        let model = DatabasePageModel(ensureReady: {})

        await model.refresh()

        #expect(model.readiness == .ready)
        #expect(model.failureDetail == nil)
    }

    @Test("Authentication failures provide a repairable technical detail")
    func authenticationFailure() async {
        let model = DatabasePageModel(ensureReady: {
            throw DatabaseBrokerAvailabilityError.unsafePeer
        })

        await model.refresh()

        #expect(
            model.failureDetail
                == "The local database service could not be verified.")
    }

    @Test("Repair replaces the service and returns the page to ready")
    func repair() async {
        let calls = DatabasePageCallRecorder()
        let model = DatabasePageModel(
            ensureReady: {
                throw DatabaseBrokerAvailabilityError.unsafePeer
            },
            repairService: {
                await calls.recordRepair()
            })

        await model.refresh()
        await model.repair()

        #expect(model.readiness == .ready)
        #expect(await calls.repairCount == 1)
    }
}

private actor DatabasePageCallRecorder {
    private(set) var repairCount = 0

    func recordRepair() {
        repairCount += 1
    }
}
