import AppKit
import EdithHostCore
import SwiftUI
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostMachinesWindowsTests {
    @Test func exactNativeCloseReleasesOnlyItsScopedSceneAndReopeningCreatesNewWindow() async throws
    {
        let fixture = MachinesWindowsFixture()
        defer { fixture.owner.close() }
        let service = fixture.service()
        try await service.open(fixture.request())
        #expect(fixture.created.count == 1 && service.pendingCount == 1)
        let first = try #require(fixture.created.first)
        #expect(!first.isVisible)
        let foreign = TestWindowHost.window(contentRect: .zero)
        foreign.close()
        await Task.yield()
        #expect(fixture.released.isEmpty && service.pendingCount == 1)
        first.close()
        await settle { service.pendingCount == 0 }
        #expect(fixture.released == fixture.loaded.map(\.presentationID))
        try await service.open(fixture.request())
        #expect(fixture.created.count == 2 && fixture.created.last !== first)
        #expect(service.pendingCount == 1)
        #expect(
            fixture.loaded.allSatisfy {
                $0.location == "machines.window" && $0.machinesWindow?.machineID == fixture.machine
            })
        try await service.stop()
        #expect(service.pendingCount == 0)
        #expect(fixture.released.count == 2)
        #expect(fixture.created.allSatisfy { !$0.isVisible })
    }

    @Test func readinessAndOwnerReplacementRejectWithoutPlaceholderSuccess() async throws {
        let fixture = MachinesWindowsFixture()
        defer { fixture.owner.close() }
        let gate = MachinesWindowGate()
        fixture.readyGate = gate
        let service = fixture.service()
        let operation = Task { try await service.open(fixture.request()) }
        await settle { gate.waiting }
        #expect(fixture.created.count == 1 && fixture.released.isEmpty)
        fixture.available = false
        gate.release()
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(service.pendingCount == 0 && fixture.released.count == 1)
        #expect(!fixture.created[0].isVisible)
        try await service.stop()
    }

    @Test func disableCancelsAndDrainsPendingLoadBeforeAnyNativeWindowExists() async throws {
        let fixture = MachinesWindowsFixture()
        defer { fixture.owner.close() }
        let gate = MachinesWindowGate()
        fixture.loadGate = gate
        let service = fixture.service()
        let open = Task { try await service.open(fixture.request()) }
        await settle { gate.waiting }
        var stopped = false
        let stop = Task {
            try await service.stop(); stopped = true
        }
        await Task.yield()
        #expect(!stopped && fixture.created.isEmpty)
        gate.release()
        try await stop.value
        await #expect(throws: CancellationError.self) { try await open.value }
        #expect(stopped && service.pendingCount == 0 && fixture.released.count == 1)
        #expect(fixture.created.isEmpty)
        fixture.loadGate = nil
        try await service.open(fixture.request())
        #expect(fixture.created.count == 1)
        try await service.stop()
    }

    @Test func failedResourceDrainRemainsPendingUntilExactRetry() async throws {
        let fixture = MachinesWindowsFixture()
        defer { fixture.owner.close() }
        fixture.releaseFails = true
        let service = fixture.service()
        try await service.open(fixture.request())
        await #expect(throws: HostWorkerError.rejected) { try await service.stop() }
        #expect(service.pendingCount == 1)
        await #expect(throws: HostWorkerError.rejected) {
            try await service.open(fixture.request())
        }
        #expect(fixture.created.count == 1)
        fixture.releaseFails = false
        try await service.stop()
        #expect(service.pendingCount == 0)
        #expect(fixture.releaseAttempts.count == 2)
        #expect(fixture.releaseAttempts[0] == fixture.releaseAttempts[1])
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

@MainActor
private final class MachinesWindowsFixture {
    let owner = TestWindowHost.window(contentRect: .zero)
    let machine = UUID()
    var available = true
    var created: [NSWindow] = []
    var loaded: [HostExtensionContentRequest] = []
    var released: [UUID] = []
    var releaseAttempts: [UUID] = []
    var loadGate: MachinesWindowGate?
    var readyGate: MachinesWindowGate?
    var releaseFails = false

    func request() throws -> HostWorkerNavigationRequest {
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.machines-owned-" + UUID().uuidString,
            supportDirectory: FileManager.default.temporaryDirectory)
        return HostWorkerNavigationRequest(
            configuration: HostWorkerConfiguration(
                identity: identity, extensionID: "machines", version: "1.0.0"),
            presentationID: UUID(),
            machinesWindow: HostMachinesWindowTarget(
                kind: .files, machineID: machine, path: "/Synthetic/Folder"))
    }

    func service() -> HostMachinesWindows {
        let windows = HostSectionWindows(
            saveFrames: false,
            makeWindow: { [self] frame in
                let window = TestWindowHost.window(
                    contentRect: frame, styleMask: [.titled, .closable, .resizable])
                created.append(window)
                return window
            }, present: { window in window.contentView?.layoutSubtreeIfNeeded() }
        ) { _ in AnyView(EmptyView()) }
        return HostMachinesWindows(
            windows: windows,
            origin: { [self] _ in
                guard available else { throw HostWorkerError.rejected }
                return owner
            },
            load: { [self] request in
                loaded.append(request)
                if let loadGate { await loadGate.wait() }
                let controller = NSViewController()
                controller.view = NSView(frame: .init(x: 0, y: 0, width: 880, height: 640))
                return controller
            },
            ready: { [self] _, window in
                window.contentView?.layoutSubtreeIfNeeded()
                if let readyGate { await readyGate.wait() }
            },
            release: { [self] id in
                releaseAttempts.append(id)
                if releaseFails { throw HostWorkerError.rejected }
                released.append(id)
            })
    }
}

@MainActor
private final class MachinesWindowGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
