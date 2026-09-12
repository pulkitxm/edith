import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct UsageMachineRefreshRequestTests {
    @Test func pendingRequestsShareTheirRunAndStrongestPolicy() async {
        let requests = UsageMachineRefreshRequests()
        let runID = await requests.enqueue(.skip)
        #expect(await requests.enqueue(.due) == runID)
        #expect(await requests.enqueue(.skip) == runID)
        #expect(await requests.enqueue(.all) == runID)
        let request = await requests.take()
        #expect(request.runID == runID)
        #expect(request.machinePolicy == .all)
    }

    @Test func requestAfterConsumptionReservesADifferentRun() async {
        let requests = UsageMachineRefreshRequests()
        let firstID = await requests.enqueue(.skip)
        let first = await requests.take()
        let nextID = await requests.enqueue(.due)
        let next = await requests.take()
        #expect(first.runID == firstID)
        #expect(first.machinePolicy == .skip)
        #expect(next.runID == nextID)
        #expect(next.machinePolicy == .due)
        #expect(nextID != firstID)
    }

    @Test func automaticCollectionsReceiveFreshIdentifiersAndDuePolicy() async {
        let requests = UsageMachineRefreshRequests()
        let first = await requests.take()
        let next = await requests.take()
        #expect(first.machinePolicy == .due)
        #expect(next.machinePolicy == .due)
        #expect(first.runID != next.runID)
    }

    @Test func refusalDiscardsOnlyTheMatchingPendingRequest() async {
        let requests = UsageMachineRefreshRequests()
        let prior = await requests.enqueue(.all)
        _ = await requests.take()
        let current = await requests.enqueue(.skip)
        await requests.discard(prior)
        let retained = await requests.take()
        #expect(retained.runID == current)
        #expect(retained.machinePolicy == .skip)

        let refused = await requests.enqueue(.all)
        await requests.discard(refused)
        let automatic = await requests.take()
        #expect(automatic.runID != refused)
        #expect(automatic.machinePolicy == .due)
    }
}
