import EdithDatabase
import Testing

@testable import Edith

@MainActor
@Suite("Database page readiness")
struct DatabasePageModelTests {
    @Test("Initial readiness succeeds without exposing service status")
    func initialReadiness() async {
        let model = DatabasePageModel(ensureReady: {}, preparePack: { _ in })

        await model.refresh()

        #expect(model.readiness == .ready)
        #expect(model.failureDetail == nil)
    }

    @Test("Authentication failures provide a repairable technical detail")
    func authenticationFailure() async {
        let model = DatabasePageModel(
            ensureReady: {
                throw DatabaseBrokerAvailabilityError.unsafePeer
            }, preparePack: { _ in })

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
            },
            preparePack: { _ in })

        await model.refresh()
        await model.repair()

        #expect(model.readiness == .ready)
        #expect(await calls.repairCount == 1)
    }

    @Test("Cancelled readiness enters a recoverable terminal state")
    func cancelledReadiness() async {
        let model = DatabasePageModel(
            ensureReady: { throw CancellationError() }, preparePack: { _ in })

        await model.refresh()

        #expect(model.readiness == .failed("The database readiness check was cancelled."))
        #expect(model.failureDetail == "The database readiness check was cancelled.")
    }

    @Test("A rejected pack checksum is shown on the page")
    func packChecksumFailure() async {
        let model = DatabasePageModel(
            ensureReady: {},
            preparePack: { _ in throw DatabasePackInstallError.checksumMismatch })
        await model.refresh()
        #expect(
            model.failureDetail
                == "The database pack checksum did not match the published digest.")
    }
}

private actor DatabasePageCallRecorder {
    private(set) var repairCount = 0

    func recordRepair() {
        repairCount += 1
    }
}
