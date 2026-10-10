import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum UsageCLIEnvironment {
    @TaskLocal static var resources: UsageCLIResources?
    static var controller: UsageWorkerController? { resources?.controller }
    static var hookOwner: UsageCLIHookOwner? { resources?.hookOwner }
    static var standardInput: Data { ExtensionCLIContext.request?.standardInput ?? Data() }
    static var workingDirectory: String { ExtensionCLIContext.request?.workingDirectory ?? "/" }

    static func forgetMachine(_ id: UUID) async throws {
        guard let resources else { throw ExtensionPeerError.unavailable }
        try await resources.forgetMachine(id)
    }
    static var machines: () -> [Machine] = { MachineRegistry.machines() }
    static var collectMachine: (Machine, TimeInterval, Bool) async throws -> Data = {
        machine, timeout, verbose in
        guard let peer = await UsageMachinesPeer.current(timeout: timeout) else {
            throw ExtensionPeerError.unavailable
        }
        if verbose {
            return try await peer.collect(
                machineID: machine.id, force: true,
                onProgress: { data, error in try CLIOut.raw(data, error: error) })
        }
        return try await peer.collect(machineID: machine.id, force: true)
    }

    static func fileURL(_ path: String) throws -> URL {
        try ExtensionCLIContext.resolvePath(path)
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
        var ownedRun: String?
        if !follow {
            let identifier = try controller.requestRefresh(policy: policy)
            if !attached { ownedRun = identifier }
        }
        var seen = 0
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                let events = controller.refreshObservation?.events ?? []
                for event in events.dropFirst(seen) { printer.show(event) }
                seen = events.count
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        await controller.waitForRefresh()
        observer.cancel()
        await observer.value
        if Task.isCancelled {
            if let ownedRun { await controller.cancelRefresh(matching: ownedRun) }
            throw CancellationError()
        }
        try Task.checkCancellation()
        if let failure = controller.failure { throw CLIFailure.unavailable(failure) }
        let result = controller.refreshObservation
        let events = result?.events ?? []
        for event in events.dropFirst(seen) { printer.show(event) }
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
            currentDirectoryURL: try ExtensionCLIContext.resolvePath("."), timeout: 10,
            maximumOutputBytes: 65_536, standardInputData: input,
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
        }
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        let resources = UsageCLIResources(
            controller: controller, hookOwner: hookOwner, forgetMachine: forgetMachine)
        return try await UsageCLIEnvironment.$resources.withValue(resources) {
            try await ExtensionCLIExecution.run(UsageCommand.self, request: request)
        }
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
