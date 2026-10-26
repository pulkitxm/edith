import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostWorkerOwnershipNotificationsTests {
    @Test func backgroundRegistrationWaitsForMainActorRejection() async throws {
        let engine = HostInProcessWorkerEngine(channel: HostWorkerChannel())
        engine.observe(owner: "fixture")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }
        let pid = process.processIdentifier
        let accepted = await Task.detached {
            var accepted: Bool?
            let accept: (Bool) -> Void = { accepted = $0 }
            NotificationCenter.default.post(
                name: ExtensionCommandOwnership.registerNotification, object: nil,
                userInfo: ["owner": "fixture", "pid": pid, "accept": accept])
            return accepted
        }.value
        #expect(accepted == false)
        _ = await engine.perform(HostWorkerRequest(operation: "stop"))
    }

    @Test func backgroundNotificationsFilterOwnersAndInvalidProcesses() async {
        let engine = HostInProcessWorkerEngine(channel: HostWorkerChannel())
        engine.observe(owner: "fixture")
        let rejected = await Task.detached {
            var accepted: Bool?
            let accept: (Bool) -> Void = { accepted = $0 }
            NotificationCenter.default.post(
                name: ExtensionCommandOwnership.registerNotification, object: nil,
                userInfo: ["owner": "other", "pid": getpid(), "accept": accept])
            let ignored = accepted == nil
            NotificationCenter.default.post(
                name: ExtensionCommandOwnership.registerNotification, object: nil,
                userInfo: ["owner": "fixture", "pid": getpid(), "accept": accept])
            NotificationCenter.default.post(
                name: ExtensionCommandOwnership.releaseNotification, object: nil,
                userInfo: ["owner": "fixture", "pid": getpid()])
            return ignored && accepted == false
        }.value
        #expect(rejected)
        _ = await engine.perform(HostWorkerRequest(operation: "stop"))
    }
}
