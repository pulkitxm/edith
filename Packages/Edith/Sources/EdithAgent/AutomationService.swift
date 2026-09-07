import EdithCore
import EdithKit
import Foundation
import IOKit.ps
import Network

public actor AutomationService {
    private let storage: AutomationStorage
    private let executor: AutomationExecutor
    private let isEnabled: @Sendable () -> Bool
    private var tasks: AgentTaskService?
    private var networkMonitor: NWPathMonitor?
    private var lastNetwork: AutomationNetworkState?
    private var lastPower: AutomationPowerSource?
    private var lastBattery: Int?
    private var scheduledMinutes: [UUID: Date] = [:]

    public init(
        storage: AutomationStorage = AutomationStorage(root: AppDirectories.current.data),
        isEnabled: @escaping @Sendable () -> Bool = {
            ExtensionRegistry.entry("automations")?.isEnabled(in: SharedDefaults.store) == true
        },
        runner: AutomationCommandRunner? = nil
    ) {
        self.storage = storage
        self.isEnabled = isEnabled
        let executable =
            Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("ed")
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("ed")
        executor = AutomationExecutor(
            runner: runner ?? { arguments in
                try await AutomationCommandProcess.run(executable: executable, arguments: arguments)
            }, storage: storage)
    }

    public func register(on runtime: AgentRuntime, tasks: AgentTaskService) async {
        self.tasks = tasks
        await runtime.register(operation: AgentAutomationOperation.load) { _ in
            try await AgentPayload.encode(self.load())
        }
        await runtime.register(operation: AgentAutomationOperation.save) { payload in
            try await self.save(AgentPayload.decode(AutomationDocument.self, from: payload))
            return Data()
        }
        await runtime.register(operation: AgentAutomationOperation.history) { _ in
            try await AgentPayload.encode(self.history())
        }
        for operation in [AgentAutomationOperation.run, AgentAutomationOperation.focusRun] {
            await tasks.register(operation: operation, concurrency: 1) { payload, _ in
                let request = try AgentPayload.decode(AgentAutomationRunRequest.self, from: payload)
                return try await AgentPayload.encode(self.execute(request))
            }
        }
        await runtime.registerShutdown(id: "automations") { await self.shutdown() }
    }

    public func load() throws -> AutomationDocument { try storage.load() }
    public func history() throws -> [AutomationRunRecord] { try storage.history() }
    public func save(_ document: AutomationDocument) throws {
        try storage.save(document)
        IPC.post(IPC.Name.settingsChanged)
    }

    public func execute(_ request: AgentAutomationRunRequest) async throws -> AutomationRunRecord {
        guard isEnabled() || request.restoresFocusState else {
            throw AutomationExecutionError.disabled
        }
        let scene: AutomationScene
        if let transient = request.transientScene {
            guard
                request.restoresFocusState
                    || ExtensionRegistry.entry("focusProfiles")?.isEnabled(in: SharedDefaults.store)
                        == true
            else { throw AgentError(.refused, "Focus Profiles is disabled.") }
            scene = transient
        } else {
            guard let stored = try storage.load().scenes.first(where: { $0.id == request.sceneID })
            else { throw AgentError(.refused, "The scene no longer exists.") }
            scene = stored
        }
        let runID = try await executor.start(
            scene: scene, automationID: request.automationID,
            origin: request.origin, grantedPermissions: request.grantedPermissions)
        let executor = executor
        let record = await withTaskCancellationHandler {
            await executor.wait(for: runID)
        } onCancel: {
            Task { await executor.cancel(runID) }
        }
        guard let record else { throw AgentError(.failed, "The scene result is unavailable.") }
        if scene.notifiesOnCompletion {
            try? await AgentNotificationService.shared.enqueue(
                AgentNotification(
                    identifier: "automation.\(record.id.uuidString)", title: record.sceneName,
                    body: record.succeeded ? "Scene completed." : "Scene finished with an error."))
        }
        return record
    }

    public func tick(now: Date = Date()) async throws -> Data? {
        guard isEnabled()
        else {
            await shutdown()
            return nil
        }
        let document = try storage.load()
        let rules = document.automations.filter(\.isEnabled)
        let wantsNetwork = rules.contains { $0.trigger.kind == .network }
        if wantsNetwork, networkMonitor == nil {
            let monitor = NWPathMonitor()
            networkMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let state: AutomationNetworkState =
                    path.status == .satisfied ? .reachable : .unreachable
                Task { await self?.networkChanged(state) }
            }
            monitor.start(queue: DispatchQueue(label: "com.pulkit.edith.agent.automations.network"))
        } else if !wantsNetwork {
            networkMonitor?.cancel()
            networkMonitor = nil
            lastNetwork = nil
        }
        let calendar = Calendar.current
        let minute = calendar.dateInterval(of: .minute, for: now)!.start
        let power = Self.powerSnapshot()
        for rule in rules {
            let matches: Bool
            switch rule.trigger {
            case let .schedule(hour, targetMinute, weekdays):
                let weekday = AutomationWeekday(rawValue: calendar.component(.weekday, from: now))!
                matches =
                    calendar.component(.hour, from: now) == hour
                    && calendar.component(.minute, from: now) == targetMinute
                    && (weekdays.isEmpty || weekdays.contains(weekday))
                    && scheduledMinutes[rule.id] != minute
                if matches { scheduledMinutes[rule.id] = minute }
            case .powerSource(let source):
                matches = lastPower != nil && power.source != lastPower && source == power.source
            case .battery(let level, let direction):
                if let previous = lastBattery, let current = power.battery {
                    matches =
                        direction == .fallsBelow
                        ? previous > level && current <= level
                        : previous < level && current >= level
                } else {
                    matches = false
                }
            default: matches = false
            }
            if matches { try await submit(rule) }
        }
        scheduledMinutes = scheduledMinutes.filter { $0.value == minute }
        lastPower = power.source
        lastBattery = power.battery
        return nil
    }

    private func networkChanged(_ state: AutomationNetworkState) async {
        defer { lastNetwork = state }
        guard lastNetwork != nil, lastNetwork != state,
            isEnabled(),
            let document = try? storage.load()
        else { return }
        for rule in document.automations where rule.isEnabled {
            if case .network(let expected) = rule.trigger, expected == state {
                try? await submit(rule)
            }
        }
    }

    private func submit(_ rule: AutomationRule) async throws {
        let permissions = Set(
            AutomationPermission.allCases.filter { permission in
                PermissionsStatus.granted.first { $0.key.rawValue == permission.rawValue }?.value
                    == true
            })
        let request = AgentAutomationRunRequest(
            sceneID: rule.sceneID, origin: .trigger,
            automationID: rule.id, grantedPermissions: permissions)
        _ = try await tasks?.submit(
            AgentTaskSubmission(
                operation: AgentAutomationOperation.run,
                title: rule.name, payload: AgentPayload.encode(request)))
    }

    public func shutdown() async {
        networkMonitor?.cancel()
        networkMonitor = nil
        lastNetwork = nil
        lastPower = nil
        lastBattery = nil
        scheduledMinutes.removeAll()
        await executor.cancelAll()
    }

    private static func powerSnapshot() -> (source: AutomationPowerSource?, battery: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, nil) }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any]
            else { continue }
            let state = description[kIOPSPowerSourceStateKey as String] as? String
            return (
                state == kIOPSACPowerValue ? .adapter : .battery,
                description[kIOPSCurrentCapacityKey as String] as? Int
            )
        }
        return (nil, nil)
    }
}
