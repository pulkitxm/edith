import EdithCore
import Foundation

public struct AutomationPlanStep: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let operationID: String
    public let summary: String
    public let command: [String]
    public let effect: UserOperationEffect
    public let requiresPreview: Bool
    public let missingPermissions: Set<AutomationPermission>
    public let timeoutSeconds: Double

    public var isRunnable: Bool { missingPermissions.isEmpty && timeoutSeconds > 0 }
}

public struct AutomationPlan: Equatable, Sendable {
    public let sceneID: UUID
    public let sceneName: String
    public let steps: [AutomationPlanStep]
    public let errors: [String]

    public var isRunnable: Bool { errors.isEmpty && steps.allSatisfy(\.isRunnable) }
    public var requiresConfirmation: Bool {
        steps.contains { $0.requiresPreview || $0.effect == .destructive }
    }
}

public enum AutomationPlanner {
    public static func plan(
        scene: AutomationScene, grantedPermissions: Set<AutomationPermission> = []
    ) -> AutomationPlan {
        var steps: [AutomationPlanStep] = []
        var errors: [String] = []
        for action in scene.actions {
            if action.operationID.hasPrefix("automations.") {
                errors.append("Automation control operations cannot be scene actions.")
                continue
            }
            guard
                let descriptor = UserOperationCatalog.descriptor(
                    id: UserOperationID(rawValue: action.operationID))
            else {
                errors.append("Unknown operation \(action.operationID).")
                continue
            }
            let descriptorPermissions = Set(
                descriptor.requiredPermissions.compactMap(AutomationPermission.init(rawValue:)))
            let required = action.requiredPermissions.union(descriptorPermissions)
            steps.append(
                AutomationPlanStep(
                    id: action.id, operationID: action.operationID,
                    summary: descriptor.summary, command: descriptor.cli + action.arguments,
                    effect: descriptor.effect, requiresPreview: descriptor.requiresPreview,
                    missingPermissions: required.subtracting(grantedPermissions),
                    timeoutSeconds: action.timeoutSeconds))
            if action.timeoutSeconds <= 0 {
                errors.append("\(action.operationID) needs a positive timeout.")
            }
        }
        if scene.actions.isEmpty { errors.append("Scene \(scene.name) has no actions.") }
        return AutomationPlan(
            sceneID: scene.id, sceneName: scene.name, steps: steps, errors: errors)
    }
}

public enum AutomationExecutionError: LocalizedError, Equatable {
    case invalidPlan([String])
    case disabled
    case alreadyRunning
    case cooldown(TimeInterval)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidPlan(let errors): errors.joined(separator: " ")
        case .disabled: "The scene is disabled."
        case .alreadyRunning: "The scene is already running."
        case .cooldown(let remaining):
            "The scene is cooling down for \(Int(ceil(remaining))) more seconds."
        case .timedOut: "The operation exceeded its time limit."
        }
    }
}

public typealias AutomationCommandRunner = @Sendable ([String]) async throws -> String

public actor AutomationExecutor {
    private let runner: AutomationCommandRunner
    private let storage: AutomationStorage?
    private var activeScenes: Set<UUID> = []
    private var lastFinished: [UUID: Date] = [:]
    private var activeRuns: [UUID: Task<AutomationRunRecord, Never>] = [:]

    public init(runner: @escaping AutomationCommandRunner, storage: AutomationStorage? = nil) {
        self.runner = runner
        self.storage = storage
    }

    public func start(
        scene: AutomationScene, automationID: UUID? = nil, origin: AutomationRunOrigin,
        grantedPermissions: Set<AutomationPermission> = [], now: Date = Date()
    ) throws -> UUID {
        guard scene.isEnabled else { throw AutomationExecutionError.disabled }
        guard !activeScenes.contains(scene.id) else {
            throw AutomationExecutionError.alreadyRunning
        }
        if let finished = lastFinished[scene.id] {
            let remaining = scene.cooldownSeconds - now.timeIntervalSince(finished)
            if remaining > 0 { throw AutomationExecutionError.cooldown(remaining) }
        }
        let plan = AutomationPlanner.plan(scene: scene, grantedPermissions: grantedPermissions)
        guard plan.isRunnable else {
            throw AutomationExecutionError.invalidPlan(plan.errors + permissionErrors(plan))
        }
        let runID = UUID()
        activeScenes.insert(scene.id)
        let runner = self.runner
        let policy = scene.errorPolicy
        activeRuns[runID] = Task {
            await Self.perform(
                runID: runID, scene: scene, automationID: automationID, origin: origin,
                plan: plan, policy: policy, runner: runner, now: now)
        }
        return runID
    }

    public func wait(for runID: UUID) async -> AutomationRunRecord? {
        guard let task = activeRuns[runID] else { return nil }
        let record = await task.value
        activeRuns[runID] = nil
        activeScenes.remove(record.sceneID)
        lastFinished[record.sceneID] = Date()
        try? storage?.append(record)
        return record
    }

    public func cancel(_ runID: UUID) {
        activeRuns[runID]?.cancel()
    }

    public func cancelAll() {
        for task in activeRuns.values { task.cancel() }
    }

    private static func perform(
        runID: UUID, scene: AutomationScene, automationID: UUID?, origin: AutomationRunOrigin,
        plan: AutomationPlan, policy: AutomationErrorPolicy,
        runner: @escaping AutomationCommandRunner,
        now: Date
    ) async -> AutomationRunRecord {
        let clock = ContinuousClock()
        let runStart = clock.now
        var results: [AutomationStepResult] = []
        for step in plan.steps {
            if Task.isCancelled {
                results.append(result(step, state: .cancelled, output: "Cancelled", duration: 0))
                break
            }
            let stepStart = clock.now
            do {
                let output = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await runner(step.command) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(step.timeoutSeconds))
                        throw AutomationExecutionError.timedOut
                    }
                    let value = try await group.next() ?? ""
                    group.cancelAll()
                    return value
                }
                results.append(
                    result(
                        step, state: .succeeded, output: output,
                        duration: duration(from: stepStart, to: clock.now)))
            } catch is CancellationError {
                results.append(
                    result(
                        step, state: .cancelled, output: "Cancelled",
                        duration: duration(from: stepStart, to: clock.now)))
                break
            } catch AutomationExecutionError.timedOut {
                results.append(
                    result(
                        step, state: .timedOut, output: "Timed out",
                        duration: duration(from: stepStart, to: clock.now)))
                if policy == .stop { break }
            } catch {
                results.append(
                    result(
                        step, state: .failed, output: error.localizedDescription,
                        duration: duration(from: stepStart, to: clock.now)))
                if policy == .stop { break }
            }
        }
        return AutomationRunRecord(
            id: runID, sceneID: scene.id, sceneName: scene.name, automationID: automationID,
            origin: origin, startedAt: now, duration: duration(from: runStart, to: clock.now),
            steps: results)
    }

    private static func result(
        _ step: AutomationPlanStep, state: AutomationStepState, output: String, duration: Double
    ) -> AutomationStepResult {
        AutomationStepResult(
            id: step.id, operationID: step.operationID, state: state, startedAt: Date(),
            duration: duration, output: output)
    }

    private static func duration(
        from start: ContinuousClock.Instant, to end: ContinuousClock.Instant
    ) -> Double {
        let value = start.duration(to: end)
        return Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
    }

    private func permissionErrors(_ plan: AutomationPlan) -> [String] {
        plan.steps.flatMap { step in
            step.missingPermissions.map { "\(step.operationID) needs \($0.rawValue) permission." }
        }
    }
}

public enum AutomationOperation: String, CaseIterable, Sendable {
    case operations
    case list
    case plan
    case run
    case enable
    case disable
    case history
    case export
    case `import`

    public var descriptor: UserOperationDescriptor {
        let effect: UserOperationEffect =
            switch self {
            case .operations, .list, .plan, .history: .read
            case .run: .interactive
            case .enable, .disable, .export, .import: .write
            }
        return UserOperationDescriptor(
            id: UserOperationID(rawValue: "automations.\(rawValue)"),
            summary: summary, cli: ["automations", rawValue], effect: effect,
            requiresPreview: self == .run || self == .import)
    }

    private var summary: String {
        switch self {
        case .operations: "List operations available to scenes"
        case .list: "List automations and scenes"
        case .plan: "Preview a scene execution plan"
        case .run: "Run a reusable scene"
        case .enable: "Enable an automation or scene"
        case .disable: "Disable an automation or scene"
        case .history: "Show recent automation results"
        case .export: "Export automations and scenes"
        case .import: "Import automations and scenes"
        }
    }
}
