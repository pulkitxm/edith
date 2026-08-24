import EdithCore
import Foundation

public enum UsageCollectionOperation: String, CaseIterable, Sendable {
    case limitsRefresh
    case refresh
    case machineEnable
    case machineDisable
    case machineCollect
    case machineForget

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: operationID), summary: summary, cli: cli,
            effect: effect)
    }

    private var operationID: String {
        switch self {
        case .limitsRefresh: "usage.limits.refresh"
        case .refresh: "usage.refresh"
        case .machineEnable: "usage.machines.enable"
        case .machineDisable: "usage.machines.disable"
        case .machineCollect: "usage.machines.collect"
        case .machineForget: "usage.machines.forget"
        }
    }

    private var cli: [String] {
        switch self {
        case .limitsRefresh: ["usage", "limits"]
        case .refresh: ["usage", "refresh"]
        case .machineEnable: ["usage", "machines", "enable"]
        case .machineDisable: ["usage", "machines", "disable"]
        case .machineCollect: ["usage", "machines", "collect"]
        case .machineForget: ["usage", "machines", "forget"]
        }
    }

    private var summary: String {
        switch self {
        case .limitsRefresh: "Poll agent providers for current rate limits."
        case .refresh: "Re-collect agent usage."
        case .machineEnable: "Include a machine in agent usage collection."
        case .machineDisable: "Stop collecting agent usage from a machine."
        case .machineCollect: "Collect agent usage from included machines."
        case .machineForget: "Drop a machine's collected agent usage."
        }
    }

    private var effect: UserOperationEffect {
        self == .machineForget ? .destructive : .write
    }
}

public enum UsageCollectionSignal: Sendable {
    case limitsRefresh
    case refresh

    public var operation: UsageCollectionOperation {
        switch self {
        case .limitsRefresh: .limitsRefresh
        case .refresh: .refresh
        }
    }

    public var notification: Notification.Name {
        switch self {
        case .limitsRefresh: IPC.Name.requestLimitsRefresh
        case .refresh: IPC.Name.requestUsageRefresh
        }
    }
}

public enum UsageCollectionOperationError: LocalizedError, Equatable, Sendable {
    case noRefreshRunning

    public var errorDescription: String? {
        switch self {
        case .noRefreshRunning: "no usage refresh is running"
        }
    }

    public var hint: String {
        switch self {
        case .noRefreshRunning: "drop --follow to start one"
        }
    }
}

public struct UsageRefreshOperationDriver: Sendable {
    public typealias Sink = @Sendable (UsageRefreshEvent) -> Void

    public var isRunning: @Sendable () -> Bool
    public var start: @Sendable (@escaping Sink) async throws -> UsageRefreshResult
    public var attach: @Sendable (@escaping Sink) async throws -> UsageRefreshResult

    public init(
        isRunning: @escaping @Sendable () -> Bool,
        start: @escaping @Sendable (@escaping Sink) async throws -> UsageRefreshResult,
        attach: @escaping @Sendable (@escaping Sink) async throws -> UsageRefreshResult
    ) {
        self.isRunning = isRunning
        self.start = start
        self.attach = attach
    }

    public static let live = UsageRefreshOperationDriver(
        isRunning: { UsageRefreshRunner.isRunning },
        start: { try await UsageRefreshRunner.run(onEvent: $0) },
        attach: { try await UsageRefreshFollower.follow(onEvent: $0) })

    public static func scripted(
        events: [UsageRefreshEvent], busy: Bool = false, failure: UsageRefreshFailure? = nil
    ) -> UsageRefreshOperationDriver {
        let replay: @Sendable (@escaping Sink) async throws -> UsageRefreshResult = { sink in
            if let failure { throw failure }
            for event in events { sink(event) }
            let seconds = events.compactMap { event -> Double? in
                guard case let .finished(value) = event else { return nil }
                return value
            }.last
            return UsageRefreshResult(
                events: events, seconds: seconds ?? 0, startedAt: Date())
        }
        return UsageRefreshOperationDriver(
            isRunning: { busy },
            start: { sink in
                if busy { throw UsageRefreshFailure.busy }
                return try await replay(sink)
            },
            attach: replay)
    }
}

public struct UsageRefreshOperationResult: Sendable {
    public let refresh: UsageRefreshResult
    public let followed: Bool

    public init(refresh: UsageRefreshResult, followed: Bool) {
        self.refresh = refresh
        self.followed = followed
    }
}

public struct UsageMachineCollectionInput: Sendable {
    public let targets: [Machine]
    public let registry: [Machine]
    public let dataDirectory: URL
    public let timeout: TimeInterval
    public let verbose: Bool

    public init(
        targets: [Machine], registry: [Machine], dataDirectory: URL,
        timeout: TimeInterval, verbose: Bool
    ) {
        self.targets = targets
        self.registry = registry
        self.dataDirectory = dataDirectory
        self.timeout = timeout
        self.verbose = verbose
    }
}

public struct UsageMachineCollectionOperationResult: Sendable {
    public let round: MachineUsageRoundResult
    public let includedMachineIDs: Set<UUID>

    public init(round: MachineUsageRoundResult, includedMachineIDs: Set<UUID>) {
        self.round = round
        self.includedMachineIDs = includedMachineIDs
    }
}

public enum UsageCollectionOperationExecution {
    public typealias EventSink = @Sendable (UsageRefreshEvent) -> Void
    public typealias MachineCollector =
        @Sendable (
            UsageMachineCollectionInput, @escaping EventSink
        ) async -> MachineUsageRoundResult

    @discardableResult
    public static func request(
        _ signal: UsageCollectionSignal,
        deliver: (Notification.Name) -> Void = { IPC.post($0) }
    ) -> UsageCollectionOperation {
        deliver(signal.notification)
        return signal.operation
    }

    public static func refresh(
        follow: Bool, driver: UsageRefreshOperationDriver,
        onBusyAttach: () -> Void = {},
        onEvent: @escaping EventSink = { _ in }
    ) async throws -> UsageRefreshOperationResult {
        if follow {
            guard driver.isRunning() else {
                throw UsageCollectionOperationError.noRefreshRunning
            }
            return UsageRefreshOperationResult(
                refresh: try await driver.attach(onEvent), followed: true)
        }
        do {
            return UsageRefreshOperationResult(
                refresh: try await driver.start(onEvent), followed: false)
        } catch UsageRefreshFailure.busy {
            onBusyAttach()
            return UsageRefreshOperationResult(
                refresh: try await driver.attach(onEvent), followed: true)
        }
    }

    @discardableResult
    public static func setMachineCounted(
        _ counted: Bool, machineID: UUID,
        store: UserDefaults = SharedDefaults.store
    ) -> UsageCollectionOperation {
        if counted {
            MachineUsageSelection.include(machineID, store)
            return .machineEnable
        }
        MachineUsageSelection.exclude(machineID, store)
        return .machineDisable
    }

    public static func collectMachines(
        _ input: UsageMachineCollectionInput,
        includeSuccessfulMachines: Bool,
        store: UserDefaults = SharedDefaults.store,
        onEvent: @escaping EventSink = { _ in },
        afterChange: @escaping () -> Void = {
            IPC.post(IPC.Name.requestUsageRefresh)
        },
        collect: @escaping MachineCollector = { input, onEvent in
            await MachineUsageRound.collect(
                input.targets, registry: input.registry, dataDir: input.dataDirectory,
                timeout: input.timeout, echoingTheCollector: input.verbose,
                onEvent: onEvent)
        }
    ) async -> UsageMachineCollectionOperationResult {
        let round = await collect(input, onEvent)
        let included = Set(
            input.targets.compactMap { machine in
                round.collected.contains { $0.machineID == machine.id } ? machine.id : nil
            })
        if includeSuccessfulMachines {
            for id in included { MachineUsageSelection.include(id, store) }
        }
        if round.changedAnything { afterChange() }
        return UsageMachineCollectionOperationResult(
            round: round, includedMachineIDs: included)
    }

    @discardableResult
    public static func forgetMachine(
        machineID: UUID,
        store: UserDefaults = SharedDefaults.store,
        directory: URL = UsageCollector.machinesDirectory,
        afterDrop: () -> Void = {
            IPC.post(IPC.Name.requestUsageRefresh)
        }
    ) -> Bool {
        let dropped = MachineUsageStore.forget(machineID: machineID, in: directory)
        MachineUsageSelection.exclude(machineID, store)
        if dropped { afterDrop() }
        return dropped
    }
}
