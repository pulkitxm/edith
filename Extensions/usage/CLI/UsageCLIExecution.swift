import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum UsageCLIEnvironment {
    static var controller: UsageWorkerController?
    static var hookOwner: UsageCLIHookOwner?
    static var forgetMachine: @MainActor (UUID) async throws -> Void = {
        try UsageMachinesPeer.forget(machineID: $0)
    }
    static var standardInput = Data()
    static var workingDirectory = FileManager.default.currentDirectoryPath
    static var machines: () -> [Machine] = { MachineRegistry.machines() }
    static var collectMachine: (Machine, TimeInterval, Bool) async throws -> Data = {
        machine, timeout, _ in
        guard let peer = await UsageMachinesPeer.current(timeout: timeout) else {
            throw ExtensionPeerError.unavailable
        }
        return try await peer.collect(machineID: machine.id, force: true)
    }

    static func fileURL(_ path: String) throws -> URL {
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.utf8.contains(0) else {
            throw CLIFailure.usage("the file path is invalid")
        }
        return URL(
            fileURLWithPath: path,
            relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)
        ).standardizedFileURL
    }

    static func refreshLimits() async throws {
        guard let controller else { throw CLIFailure.unavailable("the Usage extension is off") }
        try controller.requestLimitsRefresh()
        try await controller.waitForLimitsRefresh()
    }

    static func refresh(follow: Bool, policy: UsageMachineRefreshPolicy, json: Bool = false)
        async throws -> JSONValue
    {
        guard let controller else { throw CLIFailure.unavailable("the Usage extension is off") }
        let attached = controller.refreshing
        if follow, !attached { throw CLIFailure.unavailable("no usage refresh is running") }
        let progress = CLIProgress.forCommand(json: json)
        let printer = UsageRefreshPrinter(progress: progress)
        progress.header("EDITH · refresh usage · " + UsageRefreshPrinter.stamp(Date()))
        progress.begin(attached || follow ? "following" : "starting")
        defer { progress.end() }
        var policy = policy
        if policy == .all, !follow, !attached {
            let targets = machines().filter { UsageCLIMachines.selected.contains($0.id) }
            let round = try await UsageCLIMachines.collect(
                targets, once: true, timeout: 900, verbose: false)
            if !round.failures.isEmpty {
                throw CLIFailure.unavailable(
                    "machine usage collection failed",
                    hint: round.failures.map { "\($0.machine): \($0.reason)" }.joined(
                        separator: "; "))
            }
            policy = .skip
        }
        if !follow { _ = try controller.requestRefresh(policy: policy) }
        let observer = Task { @MainActor in
            var seen = 0
            while !Task.isCancelled {
                let events = controller.refreshObservation?.events ?? []
                for event in events.dropFirst(seen) { printer.show(event) }
                seen = events.count
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        defer { observer.cancel() }
        await withTaskCancellationHandler {
            await controller.waitForRefresh()
        } onCancel: {
            if !attached, !follow { Task { @MainActor in await controller.cancelRefresh() } }
        }
        try Task.checkCancellation()
        if let failure = controller.failure { throw CLIFailure.unavailable(failure) }
        let result = controller.refreshObservation
        let events = result?.events ?? []
        let summaries = events.compactMap { event -> (String, JSONValue)? in
            if case .summary(let label, let value) = event { return (label, .string(value)) }
            return nil
        }
        return .object([
            "completed": .bool(true), "followed": .bool(follow || attached),
            "seconds": .double(result?.seconds ?? 0),
            "summary": .object(Dictionary(summaries, uniquingKeysWith: { _, latest in latest })),
            "phases": .array(
                events.compactMap { event in
                    guard case let .phase(name, detail, seconds) = event else { return nil }
                    return .object([
                        "name": .string(name), "detail": .string(detail),
                        "seconds": .double(seconds),
                    ])
                }),
        ])
    }

    static func runStatusLine(_ command: String, input: Data) async throws -> Data {
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command], environment: ProcessInfo.processInfo.environment,
            timeout: 10, maximumOutputBytes: 65_536, standardInputData: input,
            discardsStandardError: true, terminatesProcessGroup: true)
        return try await CLICommandRunner.runLocal(request, onLine: { _ in }).standardOutputData
    }
}

@MainActor enum UsageCLIExecution {
    static func run(
        _ request: ExtensionCLIRequest, controller: UsageWorkerController,
        hookOwner: UsageCLIHookOwner? = nil,
        forgetMachine: @escaping @MainActor (UUID) async throws -> Void = {
            try UsageMachinesPeer.forget(machineID: $0)
        },
        standardInput: Data = Data(),
        workingDirectory: String = FileManager.default.currentDirectoryPath
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        guard standardInput.count <= 512 * 1_024, workingDirectory.hasPrefix("/"),
            workingDirectory.utf8.count <= 4_096, !workingDirectory.utf8.contains(0)
        else { throw ExtensionPeerError.invalidRequest }
        let previous = UsageCLIEnvironment.controller
        let previousHooks = UsageCLIEnvironment.hookOwner
        let previousForget = UsageCLIEnvironment.forgetMachine
        let previousInput = UsageCLIEnvironment.standardInput
        let previousDirectory = UsageCLIEnvironment.workingDirectory
        UsageCLIEnvironment.controller = controller
        UsageCLIEnvironment.hookOwner = hookOwner
        UsageCLIEnvironment.forgetMachine = forgetMachine
        UsageCLIEnvironment.standardInput = standardInput
        UsageCLIEnvironment.workingDirectory = workingDirectory
        defer {
            UsageCLIEnvironment.controller = previous
            UsageCLIEnvironment.hookOwner = previousHooks
            UsageCLIEnvironment.forgetMachine = previousForget
            UsageCLIEnvironment.standardInput = previousInput
            UsageCLIEnvironment.workingDirectory = previousDirectory
        }
        return try await ExtensionCLIExecution.run(UsageCommand.self, arguments: request.arguments)
    }
}

enum UsageCLIDuration {
    static func format(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
