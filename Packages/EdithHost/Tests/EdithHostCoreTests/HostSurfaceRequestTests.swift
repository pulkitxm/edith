import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostSurfaceRequestTests {
    @Test func unavailableProvidersAndNotchMakeNoRequests() async throws {
        let versions = Versions()
        let gate = Gate()
        let requests = fixture(versions, gate)
        await #expect(throws: (any Error).self) {
            try await requests.snapshot(
                providerID: "calendar", target: .home, tile: .init(.calendar))
        }
        versions.value = ["calendar": "1.0"]
        await #expect(throws: (any Error).self) {
            try await requests.snapshot(
                providerID: "calendar", target: .notch, tile: .init(.calendar))
        }
        #expect(await gate.started == 0)
        #expect(requests.pendingCount == 0)
    }

    @Test(arguments: ["disable", "update", "notch"])
    func lifecycleChangesCancelRequestsAndRejectLateReplies(mode: String)
        async throws
    {
        let versions = Versions()
        versions.value = ["calendar": "1.0", "notchShelf": "1.0"]
        let gate = Gate()
        let requests = fixture(versions, gate)
        let task = Task {
            try await requests.snapshot(
                providerID: "calendar", target: mode == "notch" ? .notch : .home,
                tile: .init(.calendar))
        }
        try await gate.waitForStarted(1)
        #expect(requests.pendingCount == 1)
        switch mode {
        case "update": versions.value["calendar"] = "1.1"
        case "notch": versions.value["notchShelf"] = nil
        default: versions.value["calendar"] = nil
        }
        requests.retain(activeVersions: versions.value)
        #expect(requests.pendingCount == 0)
        await gate.open()
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @Test func updatingOneProviderRetainsAnotherProvidersRequest() async throws {
        let versions = Versions()
        versions.value = ["calendar": "1.0", "music": "1.0"]
        let gate = Gate()
        let requests = fixture(versions, gate)
        let calendar = Task {
            try await requests.snapshot(
                providerID: "calendar", target: .home, tile: .init(.calendar))
        }
        let music = Task {
            try await requests.snapshot(providerID: "music", target: .home, tile: .init(.music))
        }
        try await gate.waitForStarted(2)
        versions.value["calendar"] = "1.1"
        requests.retain(activeVersions: versions.value)
        #expect(requests.pendingCount == 1)
        await gate.open()
        await #expect(throws: (any Error).self) { try await calendar.value }
        #expect(try await music.value.providerID == "music")
        #expect(requests.pendingCount == 0)
    }

    @Test func hidingAViewCancelsItsRequestWithoutPublishingLateContent() async throws {
        let versions = Versions()
        versions.value = ["calendar": "1.0"]
        let gate = Gate()
        let requests = fixture(versions, gate)
        let task = Task {
            try await requests.snapshot(
                providerID: "calendar", target: .home, tile: .init(.calendar))
        }
        try await gate.waitForStarted(1)
        task.cancel()
        await gate.open()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(requests.pendingCount == 0)
    }

    @Test func capacityLimitsBoundInFlightSurfaceWorkAndRecover() async throws {
        let versions = Versions()
        versions.value = ["calendar": "1.0"]
        let gate = Gate()
        let requests = fixture(versions, gate)
        let tasks = (0..<32).map { _ in
            Task {
                try await requests.snapshot(
                    providerID: "calendar", target: .home, tile: .init(.calendar))
            }
        }
        try await gate.waitForStarted(32)
        await #expect(throws: (any Error).self) {
            try await requests.snapshot(
                providerID: "calendar", target: .home, tile: .init(.calendar))
        }
        #expect(await gate.started == 32)
        await gate.open()
        for task in tasks { #expect(try await task.value.providerID == "calendar") }
        #expect(requests.pendingCount == 0)
        #expect(
            try await requests.snapshot(
                providerID: "calendar", target: .home, tile: .init(.calendar)
            ).providerID == "calendar")
    }

    @Test func commandsRequireAnActionReturnedByTheSelectedProvider() async throws {
        let versions = Versions()
        versions.value = ["calendar": "1.0"]
        let gate = Gate()
        await gate.open()
        let requests = fixture(versions, gate)
        let snapshot = SurfaceSnapshot(
            providerID: "calendar", actions: [.init("join:synthetic", "Join", "video")])
        await #expect(throws: (any Error).self) {
            try await requests.perform(
                providerID: "calendar", target: .home, tile: .init(.calendar), snapshot: snapshot,
                actionID: "delete:synthetic")
        }
        #expect(await gate.started == 0)
        #expect(
            try await requests.perform(
                providerID: "calendar", target: .home, tile: .init(.calendar), snapshot: snapshot,
                actionID: "join:synthetic"
            ).providerID == "calendar")
        #expect(await gate.started == 1)
    }

    private func fixture(_ versions: Versions, _ gate: Gate) -> HostSurfaceRequests {
        HostSurfaceRequests(activeVersions: { versions.value }) { id, _, _ in
            try await gate.read(providerID: id)
        }
    }

    @MainActor private final class Versions { var value: [String: String] = [:] }

    private actor Gate {
        private(set) var started = 0
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func read(providerID: String) async throws -> Data {
            started += 1
            if !opened { await withCheckedContinuation { waiters.append($0) } }
            return try SurfaceSnapshot(providerID: providerID).encoded()
        }
        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
        func waitForStarted(_ count: Int) async throws {
            let deadline = Date().addingTimeInterval(5)
            while started < count {
                guard Date() < deadline else { throw ExtensionPeerError.timedOut }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}
