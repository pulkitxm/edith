import Foundation
import Testing
@testable import VirtualCameraExtension

@MainActor private final class RuntimeLeaseProbe: CameraCarrierLease {
    var failBegin = false
    var failRelease = false
    var providerActive = false
    var microphoneActive = false
    var begins = 0
    var releases = 0
    var microphonePreparations = 0
    var microphoneRetirements = 0
    func begin() async throws -> Bool {
        begins += 1
        if failBegin { throw CocoaError(.fileReadUnknown) }
        return !providerActive
    }
    func providerExited() async throws -> Bool { !providerActive }
    func prepareMicrophone() async throws {
        microphonePreparations += 1
        microphoneActive = true
    }
    func retireMicrophone() async throws {
        microphoneRetirements += 1
        microphoneActive = false
    }
    func release() async throws {
        releases += 1
        if failRelease { throw CocoaError(.fileWriteUnknown) }
        #expect(!providerActive)
        #expect(!microphoneActive)
    }
}

@MainActor private final class RuntimeBrokerProbe: CameraSystemExtensionSubmitting {
    let lease: RuntimeLeaseProbe
    var submissions = 0
    init(_ lease: RuntimeLeaseProbe) { self.lease = lease }
    func submit(
        _ operation: CameraSystemExtensionOperation, identifier: String,
        completion: @escaping @MainActor (CameraSystemExtensionEvent) -> Void
    ) {
        submissions += 1
        lease.providerActive = operation == .activate
        completion(.completed)
    }
}

@Suite(.serialized) @MainActor struct CameraCarrierRuntimeTests {
    @Test func rejectedCallerCannotAcquireAnyLease() {
        let lease = RuntimeLeaseProbe()
        let input = Pipe(), output = Pipe()
        var exited = false
        let runtime = CameraCarrierRuntime(
            environment: .init(
                admit: { throw CocoaError(.fileReadNoPermission) }, lease: { _, _, _ in lease },
                broker: { RuntimeBrokerProbe(lease) }, input: input.fileHandleForReading,
                output: output.fileHandleForWriting, exited: { exited = true }))
        #expect((runtime.execute(start()) as? NSDictionary)?["ok"] as? Bool == false)
        #expect(!runtime.started)
        #expect(lease.begins == 0)
        #expect(!exited)
    }

    @Test func failedStartupRetainsLeaseUntilRestorationAcknowledges() async throws {
        let lease = RuntimeLeaseProbe()
        lease.failBegin = true; lease.failRelease = true
        let input = Pipe(), output = Pipe()
        var exited = false
        let runtime = CameraCarrierRuntime(
            environment: .init(
                admit: {}, lease: { _, _, _ in lease }, broker: { RuntimeBrokerProbe(lease) },
                input: input.fileHandleForReading, output: output.fileHandleForWriting,
                exited: { exited = true }, retryInterval: .milliseconds(10)))
        #expect((runtime.execute(start()) as? NSDictionary)?["ok"] as? Bool == true)
        try await wait { lease.releases > 1 }
        #expect(runtime.startupFailed)
        #expect(!exited)
        lease.failRelease = false
        try await wait { exited }
    }

    @Test func pipeCommandsAndDisconnectDrainOwnedProviderAndMicrophone() async throws {
        let lease = RuntimeLeaseProbe()
        let broker = RuntimeBrokerProbe(lease)
        let input = Pipe(), output = Pipe()
        var exited = false
        let runtime = CameraCarrierRuntime(
            environment: .init(
                admit: {}, lease: { _, _, _ in lease }, broker: { broker },
                input: input.fileHandleForReading, output: output.fileHandleForWriting,
                exited: { exited = true }, retryInterval: .milliseconds(10)))
        #expect((runtime.execute(start()) as? NSDictionary)?["ok"] as? Bool == true)
        try await wait { input.fileHandleForReading.readabilityHandler != nil }
        try input.fileHandleForWriting.write(
            contentsOf: CameraCarrierFrames.encode(
                CameraCarrierRequest(token: UUID(), operation: .activate)))
        try await wait { lease.providerActive }
        try input.fileHandleForWriting.write(
            contentsOf: CameraCarrierFrames.encode(
                CameraCarrierRequest(token: UUID(), operation: .microphonePrepare)))
        try await wait { lease.microphoneActive }
        #expect(lease.releases == 0)
        try input.fileHandleForWriting.close()
        try await wait { exited }
        #expect(broker.submissions == 2)
        #expect(lease.microphoneRetirements == 1)
        #expect(lease.releases == 1)
        #expect(input.fileHandleForReading.readabilityHandler == nil)
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        try output.fileHandleForReading.close()
    }

    @Test func fixtureProbeDoesNotRegisterSystemServices() {
        let lease = RuntimeLeaseProbe()
        let runtime = CameraCarrierRuntime()
        let result = runtime.execute(["operation": "probe", "fixture": true]) as? NSDictionary
        #expect(result?["ok"] as? Bool == true)
        #expect(result?["systemServiceStarted"] as? Bool == false)
        #expect(lease.begins == 0)
        #expect(!runtime.started)
        #expect(
            (runtime.execute(["operation": "probe", "fixture": false]) as? NSDictionary)?["ok"]
                as? Bool == false)
    }

    private func start() -> NSDictionary {
        [
            "operation": "start", "hostIdentifier": "com.pulkit.edith.tests.camera",
            "version": "1.0.0", "fixture": false,
        ]
    }
    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
