import Foundation

public enum HostAgentCommandOperation: String, Codable, CaseIterable, Sendable {
    case submit = "task.submit"
    case status = "task.status"
    case cancel = "task.cancel"
    case list = "task.list"
    case scheduleAdd = "schedule.add"
    case scheduleList = "schedule.list"
    case scheduleRemove = "schedule.remove"
    case scheduleEnabled = "schedule.enable"
    case scheduleRun = "schedule.run"

    public var mutates: Bool {
        switch self {
        case .status, .list, .scheduleList: false
        default: true
        }
    }
}

public actor HostAgentCommandService {
    public static let maximumRequestBytes = 8 << 20
    public static let maximumResponseBytes = 12 << 20
    public let tasks: HostAgentTaskService
    public let schedules: HostAgentScheduleService
    private enum State { case idle, starting, running, stopping, stopped }
    private var state: State = .idle

    public init(
        directory: URL, environment: @escaping @Sendable () -> [String: String],
        publish: @escaping HostAgentTaskService.Publish = { _, _ in },
        record: @escaping HostAgentTaskService.RecordEvent = { _ in }
    ) throws {
        let journal = try HostAgentJournal(directory: directory)
        tasks = try HostAgentTaskService(
            directory: journal.directory.appendingPathComponent("Tasks"), publish: publish,
            record: record)
        schedules = try HostAgentScheduleService(
            directory: journal.directory.appendingPathComponent("Schedules"), tasks: tasks,
            environment: environment, record: record)
    }

    public func start() async throws {
        guard state == .idle else {
            if state == .running { return }
            throw HostAgentCommandError(
                .unavailable, "The core command service is not ready to start.")
        }
        state = .starting
        await tasks.registerCommand()
        do {
            guard state == .starting else {
                throw HostAgentCommandError(
                    .unavailable, "The core command service stopped during startup.")
            }
            try await schedules.start()
            guard state == .starting else {
                throw HostAgentCommandError(
                    .unavailable, "The core command service stopped during startup.")
            }
            state = .running
        } catch {
            await shutdown()
            throw error
        }
    }

    public func shutdown() async {
        guard state != .stopped else { return }
        if state == .stopping {
            while state != .stopped { await Task.yield() }
            return
        }
        state = .stopping
        await schedules.shutdown()
        await tasks.shutdown()
        state = .stopped
    }

    public func execute(_ operation: HostAgentCommandOperation, payload: Data = Data("{}".utf8))
        async throws -> Data
    {
        guard state == .running else {
            throw HostAgentCommandError(.unavailable, "The core command service is not running.")
        }
        guard payload.count <= Self.maximumRequestBytes else {
            throw HostAgentCommandError(.refused, "The core command request is too large.")
        }
        let response: Data
        switch operation {
        case .submit:
            let request = try HostAgentPayload.decode(HostAgentTaskSubmission.self, from: payload)
            guard request.operation == HostAgentTaskOperation.command else {
                throw HostAgentCommandError(
                    .unknownOperation, "The core queue accepts command.run tasks only.")
            }
            response = try HostAgentPayload.encode(await tasks.submit(request))
        case .status:
            let request = try HostAgentPayload.decode(HostAgentTaskIDRequest.self, from: payload)
            response = try HostAgentPayload.encode(await tasks.status(request.id))
        case .cancel:
            let request = try HostAgentPayload.decode(HostAgentTaskIDRequest.self, from: payload)
            response = try HostAgentPayload.encode(await tasks.cancel(request.id))
        case .list:
            response = try HostAgentPayload.encode(await tasks.snapshots())
        case .scheduleAdd:
            response = try HostAgentPayload.encode(
                await schedules.add(
                    HostAgentPayload.decode(HostScheduledTaskDefinition.self, from: payload)))
        case .scheduleList:
            response = try HostAgentPayload.encode(await schedules.list())
        case .scheduleRemove:
            let request = try HostAgentPayload.decode(
                HostAgentScheduleNameRequest.self, from: payload)
            try await schedules.remove(request.name)
            response = Data("{}".utf8)
        case .scheduleEnabled:
            let request = try HostAgentPayload.decode(
                HostAgentScheduleEnabledRequest.self, from: payload)
            response = try HostAgentPayload.encode(
                await schedules.setEnabled(request.name, request.enabled))
        case .scheduleRun:
            let request = try HostAgentPayload.decode(
                HostAgentScheduleNameRequest.self, from: payload)
            response = try HostAgentPayload.encode(await schedules.runNow(request.name))
        }
        guard response.count <= Self.maximumResponseBytes else {
            throw HostAgentCommandError(.refused, "The core command response is too large.")
        }
        return response
    }
}
