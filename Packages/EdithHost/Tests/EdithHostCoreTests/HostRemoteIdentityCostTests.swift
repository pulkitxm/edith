import Darwin
import Foundation
import Testing
@testable import EdithHostCore

struct HostRemoteIdentityCostTests {
    private func microseconds(_ iterations: Int, _ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        for _ in 0..<iterations { body() }
        let elapsed = ContinuousClock.now - start
        return
            (Double(elapsed.components.seconds) * 1e6
            + Double(elapsed.components.attoseconds) / 1e12) / Double(iterations)
    }

    @Test func livenessChecksOnlyTheProcessGenerationAndIsCheaperThanTheFullIdentityRead() throws {
        let identity = try HostRemoteKernelIdentity.read(getpid())
        #expect(identity.isAlive)
        #expect(identity.isRunning)
        let stale = HostRemoteKernelIdentity(
            pid: identity.pid, generation: "0:0", executable: identity.executable)
        #expect(!stale.isAlive)
        #expect(!stale.isRunning)
        let reusedPID = HostRemoteKernelIdentity(
            pid: 1, generation: identity.generation, executable: identity.executable)
        #expect(!reusedPID.isAlive)
        let alive = microseconds(200) { _ = identity.isAlive }
        let running = microseconds(200) { _ = identity.isRunning }
        print("LATENCY isAlive us", alive, "isRunning us", running)
        #expect(alive <= running)
    }
}
