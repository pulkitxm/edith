import CoreFoundation
import Foundation
import Testing

@testable import EdithHostCore

@MainActor @Suite(.serialized) struct HostWorkerSynchronizationTests {
    private let identifier = "com.pulkit.edith.tests.worker-" + UUID().uuidString
    @Test(arguments: HostAmbientPolicy.jobs.keys.sorted())
    func demandOnlyUsesDistinctTrustedOperationWithoutSettingsSideEffects(owner: String)
        async throws
    {
        let current = try configuration(owner: owner, pause: true)
        let coordinator = HostAmbientPolicyCoordinator()
        let identity = HostAmbientPolicyOwner(
            id: owner, version: "1", processIdentifier: 42, processGeneration: "synthetic-birth")
        if let topic = HostAmbientPolicy.jobs[owner]?.first(where: {
            HostAmbientPolicy.liveJobs.contains($0)
        }) {
            try coordinator.visible(presentation: UUID(), owner: identity, job: topic)
        }
        let policy = coordinator.policy(owner: identity, pauseAmbientOnBattery: true)
        let next = try configuration(owner: owner, pause: true, appearance: "dark", zoom: 1.4)
            .replacingAmbientPolicy(policy)
        var appearances = 0
        var settingsCallbacks = 0
        var runtimeApplies = 0
        var workerState = current
        let clientState = try await HostWorkerSynchronization.ambientPolicy.acknowledged(
            current: current, next: next,
            send: { request in
                let decoded = try wire(request)
                #expect(decoded.operation == "ambientPolicy")
                workerState = try HostWorkerSynchronization.ambientPolicy.apply(
                    decoded, current: workerState,
                    appearance: { _ in appearances += 1 },
                    synchronize: { id, context in
                        #expect(id == owner)
                        try expectIdentityContext(context, configuration: next)
                        let flag = try #require(context["ambientPolicyOnly"])
                        #expect(CFGetTypeID(flag as CFTypeRef) == CFBooleanGetTypeID())
                        #expect(context["ambientPolicyOnly"] as? Bool == true)
                        if context["ambientPolicyOnly"] as? Bool != true { settingsCallbacks += 1 }
                        runtimeApplies += 1
                        let policy = try #require(context["ambientPolicy"] as? NSDictionary)
                        #expect(policy["pauseAmbientOnBattery"] as? Bool == true)
                        #expect(
                            policy["subscribers"] as? [String: Int]
                                == next.ambientPolicy.subscribers)
                    })
                return .init(token: decoded.token, ok: true, version: workerState.version)
            })
        #expect(appearances == 0 && settingsCallbacks == 0 && runtimeApplies == 1)
        #expect(clientState.ambientPolicy == next.ambientPolicy)
        #expect(workerState.ambientPolicy == next.ambientPolicy)
        #expect(clientState.appearance == current.appearance && clientState.zoom == current.zoom)
        #expect(workerState.appearance == current.appearance && workerState.zoom == current.zoom)
    }

    @Test(arguments: HostAmbientPolicy.jobs.keys.sorted())
    func ordinarySettingsReachEveryOwnerAndRetainCurrentVisibleCounts(owner: String) async throws {
        let coordinator = HostAmbientPolicyCoordinator()
        let identity = HostAmbientPolicyOwner(
            id: owner, version: "1", processIdentifier: 42, processGeneration: "synthetic-birth")
        if let topic = HostAmbientPolicy.jobs[owner]?.first(where: {
            HostAmbientPolicy.liveJobs.contains($0)
        }) {
            try coordinator.visible(presentation: UUID(), owner: identity, job: topic)
        }
        var clientState = try configuration(owner: owner)
        var workerState = clientState
        let policy = coordinator.policy(owner: identity, pauseAmbientOnBattery: true)
        clientState = try await HostWorkerSynchronization.ambientPolicy.acknowledged(
            current: clientState, next: clientState.replacingAmbientPolicy(policy),
            send: { request in
                workerState = try HostWorkerSynchronization.ambientPolicy.apply(
                    try wire(request), current: workerState,
                    appearance: { _ in
                        Issue.record("Policy-only synchronization applied appearance")
                    }, synchronize: { _, _ in })
                return .init(token: request.token, ok: true, version: workerState.version)
            })
        var appearances = 0
        var settingsCallbacks = 0
        let appearance = try configuration(owner: owner, appearance: "dark", zoom: 1.4)
            .replacingAmbientPolicy(
                coordinator.policy(owner: identity, pauseAmbientOnBattery: true))
        clientState = try await HostWorkerSynchronization.settings.acknowledged(
            current: clientState, next: appearance,
            send: { request in
                let decoded = try wire(request)
                #expect(decoded.operation == "synchronize")
                workerState = try HostWorkerSynchronization.settings.apply(
                    decoded, current: workerState,
                    appearance: { value in
                        appearances += 1
                        #expect(value.appearance == "dark" && value.zoom == 1.4)
                    },
                    synchronize: { id, context in
                        #expect(id == owner && context["ambientPolicyOnly"] == nil)
                        try expectIdentityContext(context, configuration: appearance)
                        settingsCallbacks += 1
                        let value = try #require(context["ambientPolicy"] as? NSDictionary)
                        #expect(value["subscribers"] as? [String: Int] == policy.subscribers)
                    })
                return .init(token: decoded.token, ok: true, version: workerState.version)
            })
        #expect(appearances == 1 && settingsCallbacks == 1)
        #expect(clientState.appearance == "dark" && workerState.appearance == "dark")
        #expect(clientState.ambientPolicy == policy && workerState.ambientPolicy == policy)
        #expect(clientState.ambientPolicy.subscribers == policy.subscribers)
    }

    @Test(arguments: [
        "identifier", "extensionID", "version", "supportDirectory", "recoveryOnly", "demand",
    ])
    func incompatiblePolicyContextNeverReachesRuntime(field: String) async throws {
        let current = try configuration(owner: "usage")
        var object =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(current))
            as! [String: Any]
        if field == "recoveryOnly" {
            object[field] = true
        } else if field == "demand" {
            object["ambientPolicy"] = [
                "pauseAmbientOnBattery": true,
                "subscribers": ["usage.refresh": 1, "usage.limits": 0],
            ]
        } else {
            object[field] = field == "supportDirectory" ? "file:///synthetic/other/" : "other"
        }
        let next = try JSONDecoder().decode(
            HostWorkerConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        var sent = false
        await #expect(throws: (any Error).self) {
            _ = try await HostWorkerSynchronization.ambientPolicy.acknowledged(
                current: current, next: next,
                send: { request in
                    sent = true
                    return .init(token: request.token, ok: true, version: current.version)
                })
        }
        #expect(!sent)
        #expect(throws: (any Error).self) {
            _ = try HostWorkerSynchronization.ambientPolicy.apply(
                .init(operation: "ambientPolicy", configuration: next), current: current,
                appearance: { _ in Issue.record("Rejected context applied appearance") },
                synchronize: { _, _ in Issue.record("Rejected context reached runtime") })
        }
    }

    @Test func nonAmbientAndRecoveryOwnersRejectPolicyOnlyAndOrdinaryOwnerStillReceivesSettings()
        throws
    {
        for owner in ["downloads", "usage"] {
            var current = try configuration(owner: owner)
            if owner == "usage" { current.recoveryOnly = true }
            #expect(throws: HostWorkerError.rejected) {
                _ = try HostWorkerSynchronization.ambientPolicy.apply(
                    .init(operation: "ambientPolicy", configuration: current), current: current,
                    appearance: { _ in Issue.record("Rejected owner applied appearance") },
                    synchronize: { _, _ in Issue.record("Rejected owner reached runtime") })
            }
        }
        let current = try configuration(owner: "downloads")
        var applied = false
        _ = try HostWorkerSynchronization.settings.apply(
            .init(operation: "synchronize", configuration: current), current: current,
            appearance: { _ in },
            synchronize: { id, context in
                applied = true
                #expect(id == "downloads" && context["ambientPolicy"] == nil)
                #expect(context["ambientPolicyOnly"] == nil)
                try expectIdentityContext(context, configuration: current)
            })
        #expect(applied)
    }

    private func expectIdentityContext(
        _ context: NSDictionary, configuration: HostWorkerConfiguration
    ) throws {
        let identity = try configuration.identity()
        #expect(context["hostIdentifier"] as? String == identity.identifier)
        #expect(
            context["defaultsSuite"] as? String
                == identity.extensionDefaultsSuite(configuration.extensionID))
        #expect(
            context["dataDirectory"] as? String
                == identity.extensionDirectory(configuration.extensionID).path)
    }

    @Test(arguments: ["version", "token", "rejected", "cancelled", "error"])
    func onlyMatchingSuccessfulUncancelledAcknowledgmentReturnsConfiguration(outcome: String)
        async throws
    {
        let current = try configuration(owner: "usage")
        let next = current.replacingAmbientPolicy(
            .initial(owner: "usage", pauseAmbientOnBattery: true))
        let task = Task { @MainActor in
            try await HostWorkerSynchronization.ambientPolicy.acknowledged(
                current: current, next: next,
                send: { request in
                    if outcome == "error" { throw HostWorkerError.exited }
                    if outcome == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
                    return .init(
                        token: outcome == "token" ? UUID() : request.token,
                        ok: outcome != "rejected", version: outcome == "version" ? "2" : "1")
                })
        }
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(!current.ambientPolicy.pauseAmbientOnBattery)
    }

    @Test
    func
        runtimeFailureDoesNotAcknowledgePartialStateAndPolicyRouteCannotBeForgedBySettingsOperation()
        throws
    {
        let current = try configuration(owner: "companion")
        let next = current.replacingAmbientPolicy(
            .initial(owner: "companion", pauseAmbientOnBattery: true))
        var state = current
        #expect(throws: HostWorkerError.rejected) {
            state = try HostWorkerSynchronization.ambientPolicy.apply(
                .init(operation: "ambientPolicy", configuration: next), current: state,
                appearance: { _ in Issue.record("Policy-only route applied appearance") },
                synchronize: { _, _ in throw HostWorkerError.rejected })
        }
        #expect(!state.ambientPolicy.pauseAmbientOnBattery)
        #expect(throws: HostWorkerError.rejected) {
            _ = try HostWorkerSynchronization.ambientPolicy.apply(
                .init(operation: "synchronize", configuration: next), current: current,
                appearance: { _ in Issue.record("Wrong operation applied appearance") },
                synchronize: { _, _ in Issue.record("Wrong operation reached runtime") })
        }
    }

    private func wire(_ request: HostWorkerRequest) throws -> HostWorkerRequest {
        var frames = HostWorkerFrames()
        let frame = try #require(frames.append(HostWorkerFrames.encode(request)).first)
        return try JSONDecoder().decode(HostWorkerRequest.self, from: frame)
    }

    private func configuration(
        owner: String, pause: Bool = false, appearance: String = "system", zoom: Double = 1
    ) throws -> HostWorkerConfiguration {
        let policy = HostAmbientPolicy.initial(owner: owner, pauseAmbientOnBattery: pause)
        let object: [String: Any] = [
            "identifier": identifier, "supportDirectory": "file:///synthetic/support/",
            "extensionID": owner, "version": "1", "theme": "accent", "appearance": appearance,
            "zoom": zoom, "recoveryOnly": false,
            "ambientPolicy": ["pauseAmbientOnBattery": pause, "subscribers": policy.subscribers],
        ]
        return try JSONDecoder().decode(
            HostWorkerConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
