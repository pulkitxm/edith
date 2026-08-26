import EdithKit
import Foundation

@MainActor
final class LidAwakeActionBridge {
    static let shared = LidAwakeActionBridge()

    private var token: NSObjectProtocol?
    private let lifecycleSequencer = LidAwakeMutationSequencer()

    static func shouldWaitForRestoration(
        engineAvailable: Bool, restorationInFlight: Bool
    ) -> Bool {
        !engineAvailable && restorationInFlight
    }

    static func unavailableOutcome(
        for request: LidAwakeRequest, storedActive: Bool
    ) -> LidAwakeOutcome {
        switch request {
        case .on:
            .failed("The Lid Awake extension could not start.")
        case .off where storedActive:
            .failed("Normal lid-close sleep is still disabled, but Lid Awake is unavailable.")
        case .status, .off:
            .applied
        case .enableExtension:
            .failed("The Lid Awake extension could not be enabled.")
        case .disableExtension:
            .failed("The Lid Awake extension could not be disabled safely.")
        case .setBatteryThreshold, .setRestoreOnQuit:
            .failed("The Lid Awake request is not a runtime action.")
        }
    }

    func install(services: AppServices) {
        guard token == nil else { return }
        token = IPC.observe(
            IPC.Name.requestLidAwakeAction,
            info: { [weak self] info in
                MainActor.assumeIsolated {
                    self?.receive(info, services: services)
                }
            })
    }

    private func receive(_ info: [AnyHashable: Any], services: AppServices) {
        guard let context = LidAwakeRuntimeRequestContext(runtimePayload: info) else { return }
        guard context.isLive() else {
            IPC.post(
                IPC.Name.lidAwakeActionResult,
                userInfo: Self.inactiveSnapshot().resultPayload(
                    .failed("The Lid Awake request expired before it could run."),
                    requestID: context.requestID))
            return
        }
        guard let runtimeRequest = LidAwakeRuntimeRequest(runtimePayload: info) else {
            let payload: [String: Any] = [
                LidAwakeIPC.okKey: false,
                LidAwakeIPC.errorKey: "The Lid Awake action is invalid.",
                LidAwakeIPC.requestIDKey: context.requestID,
            ]
            IPC.post(IPC.Name.lidAwakeActionResult, userInfo: payload)
            return
        }
        if runtimeRequest.request == .status {
            let snapshot = services.lidAwake?.snapshot() ?? Self.inactiveSnapshot()
            IPC.post(
                IPC.Name.lidAwakeActionResult,
                userInfo: snapshot.resultPayload(
                    .applied, requestID: runtimeRequest.context.requestID))
            return
        }
        lifecycleSequencer.enqueue { [weak self] in
            guard let self else { return }
            await self.performMutation(runtimeRequest, services: services)
        }
    }

    private func performMutation(
        _ runtimeRequest: LidAwakeRuntimeRequest, services: AppServices
    ) async {
        if services.lidAwakeRestorationInFlight {
            _ = await services.waitForLidAwakeRestoration()
        }
        guard runtimeRequest.context.isLive() else {
            postExpired(runtimeRequest.context.requestID)
            return
        }
        let requestID = runtimeRequest.context.requestID
        switch runtimeRequest.request {
        case .enableExtension:
            _ = LidAwakeOperationExecution.enableExtension()
            services.sync()
            let snapshot = services.lidAwake?.snapshot() ?? Self.inactiveSnapshot()
            let outcome: LidAwakeOutcome =
                services.lidAwake == nil
                ? .failed("The Lid Awake extension could not be enabled.") : .applied
            IPC.post(
                IPC.Name.lidAwakeActionResult,
                userInfo: snapshot.resultPayload(outcome, requestID: requestID))
        case .disableExtension:
            let outcome = await services.disableLidAwakeExtension()
            let snapshot = services.lidAwake?.snapshot() ?? Self.inactiveSnapshot()
            IPC.post(
                IPC.Name.lidAwakeActionResult,
                userInfo: snapshot.resultPayload(outcome, requestID: requestID))
        case .on:
            if services.lidAwake == nil {
                _ = LidAwakeOperationExecution.enableExtension()
                services.sync()
            }
            guard runtimeRequest.context.isLive() else {
                postExpired(requestID)
                return
            }
            await performEngineMutation(
                runtimeRequest.request, requestID: requestID, services: services)
        case .off:
            guard runtimeRequest.context.isLive() else {
                postExpired(requestID)
                return
            }
            if let engine = services.lidAwake {
                let outcome = await engineOutcome(runtimeRequest.request, engine: engine)
                IPC.post(
                    IPC.Name.lidAwakeActionResult,
                    userInfo: engine.resultPayload(outcome, requestID: requestID))
            } else {
                let snapshot = Self.inactiveSnapshot()
                let outcome =
                    snapshot.active
                    ? await services.recoverOrphanedLidAwake() : LidAwakeOutcome.applied
                IPC.post(
                    IPC.Name.lidAwakeActionResult,
                    userInfo: Self.inactiveSnapshot().resultPayload(
                        outcome, requestID: requestID))
            }
        case .status, .setBatteryThreshold, .setRestoreOnQuit:
            let outcome = Self.unavailableOutcome(
                for: runtimeRequest.request,
                storedActive: SharedDefaults.store.bool(forKey: LidAwakeState.activeKey))
            IPC.post(
                IPC.Name.lidAwakeActionResult,
                userInfo: Self.inactiveSnapshot().resultPayload(
                    outcome, requestID: requestID))
        }
    }

    private func performEngineMutation(
        _ request: LidAwakeRequest, requestID: String, services: AppServices
    ) async {
        guard let engine = services.lidAwake else {
            let snapshot = Self.inactiveSnapshot()
            let outcome = Self.unavailableOutcome(for: request, storedActive: snapshot.active)
            IPC.post(
                IPC.Name.lidAwakeActionResult,
                userInfo: snapshot.resultPayload(outcome, requestID: requestID))
            return
        }
        let outcome = await engineOutcome(request, engine: engine)
        IPC.post(
            IPC.Name.lidAwakeActionResult,
            userInfo: engine.resultPayload(outcome, requestID: requestID))
    }

    private func engineOutcome(
        _ request: LidAwakeRequest, engine: LidAwakeEngine
    ) async -> LidAwakeOutcome {
        await withCheckedContinuation { continuation in
            engine.execute(request) { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }

    private func postExpired(_ requestID: String) {
        IPC.post(
            IPC.Name.lidAwakeActionResult,
            userInfo: Self.inactiveSnapshot().resultPayload(
                .failed("The Lid Awake request expired before it could run."),
                requestID: requestID))
    }

    static func inactiveSnapshot(
        defaults: UserDefaults = SharedDefaults.store
    ) -> LidAwakeSnapshot {
        LidAwakeSnapshot(
            storedIn: defaults, appRunning: true, helperStatus: "notRegistered")
    }
}
