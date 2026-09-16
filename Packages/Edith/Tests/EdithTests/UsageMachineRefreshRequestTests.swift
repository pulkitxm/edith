import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct UsageMachineRefreshRequestTests {
    @Test func pendingRequestsShareTheirRunAndStrongestPolicy() {
        let requests = UsageMachineRefreshRequests()
        let runID = requests.enqueue(.skip)
        #expect(requests.enqueue(.due) == runID)
        #expect(requests.enqueue(.skip) == runID)
        #expect(requests.enqueue(.all) == runID)
        let request = requests.take()
        #expect(request.runID == runID)
        #expect(request.machinePolicy == .all)
    }

    @Test func requestAfterConsumptionReservesADifferentRun() {
        let requests = UsageMachineRefreshRequests()
        let firstID = requests.enqueue(.skip)
        let first = requests.take()
        let nextID = requests.enqueue(.due)
        let next = requests.take()
        #expect(first.runID == firstID)
        #expect(first.machinePolicy == .skip)
        #expect(next.runID == nextID)
        #expect(next.machinePolicy == .due)
        #expect(nextID != firstID)
    }

    @Test func automaticCollectionsReceiveFreshIdentifiersAndDuePolicy() {
        let requests = UsageMachineRefreshRequests()
        let first = requests.take()
        let next = requests.take()
        #expect(first.machinePolicy == .due)
        #expect(next.machinePolicy == .due)
        #expect(first.runID != next.runID)
    }

    @Test func refusalDiscardsOnlyTheMatchingPendingRequest() {
        let requests = UsageMachineRefreshRequests()
        let prior = requests.enqueue(.all)
        _ = requests.take()
        let current = requests.enqueue(.skip)
        requests.discard(prior)
        let retained = requests.take()
        #expect(retained.runID == current)
        #expect(retained.machinePolicy == .skip)

        let refused = requests.enqueue(.all)
        requests.discard(refused)
        let automatic = requests.take()
        #expect(automatic.runID != refused)
        #expect(automatic.machinePolicy == .due)
    }

    @Test(arguments: ["cancel", "stop", "replace"])
    func schedulerCancellationFailsOnlyTheReservedPendingRun(action: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = UsageMachineRefreshRequests(dataDirectory: directory)
        let scheduler = JobScheduler()
        let descriptor = AgentJobDescriptor(
            id: "fixture.refresh", title: "Fixture", trigger: .timer, topic: .usage,
            cadence: .onDemand)
        await scheduler.register(
            AgentJob(descriptor: descriptor, cancelPending: { requests.cancelPending() }) { nil })
        let cancelled = requests.enqueue(.all)
        switch action {
        case "cancel": await scheduler.cancel(descriptor.id)
        case "stop": await scheduler.stop()
        default: await scheduler.register(AgentJob(descriptor: descriptor) { nil })
        }
        await #expect(throws: UsageRefreshFailure.self) {
            try await UsageRefreshFollower.follow(dataDir: directory, runID: cancelled)
        }
        let next = requests.enqueue(.skip)
        let retained = requests.take()
        #expect(retained.runID == next)
        #expect(retained.runID != cancelled)
        #expect(retained.machinePolicy == .skip)
        #expect(
            !FileManager.default.fileExists(
                atPath: UsageRefreshRunner.runEventsURL(runID: next, dataDir: directory).path))
        await scheduler.shutdown()
    }

}
