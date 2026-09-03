import AppKit
import EdithKit
import Foundation

public struct CLIRemoteDirectoryTarget: Sendable {
    public let machine: Machine
    public let endpoint: RemoteDirectoryEndpoint
    public let platform: RemoteMachinePlatform

    public init(
        machine: Machine, endpoint: RemoteDirectoryEndpoint,
        platform: RemoteMachinePlatform = .linux
    ) {
        self.machine = machine
        self.endpoint = endpoint
        self.platform = platform
    }
}

public enum CLIEnvironment {
    nonisolated(unsafe) public static var sharedDefaults: UserDefaults = {
        guard let suite = ProcessInfo.processInfo.environment["EDITH_TEST_SHARED_DEFAULTS_SUITE"],
            let defaults = UserDefaults(suiteName: suite)
        else { return SharedDefaults.store }
        defaults.register(defaults: SharedDefaults.registeredDefaults)
        return defaults
    }()
    nonisolated(unsafe) public static var standardDefaults: UserDefaults = .standard

    nonisolated(unsafe) public static var isHelperRunning: @Sendable () -> Bool = {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: AppBridge.helperBundleID
        ).isEmpty
    }

    nonisolated(unsafe) public static var isMainAppRunning: @Sendable () -> Bool = {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: AppBridge.mainBundleID
        ).isEmpty
    }

    nonisolated(unsafe) public static var deliver:
        @Sendable (Notification.Name, [String: Any]?) -> Void = {
            IPC.post($0, userInfo: $1)
        }

    nonisolated(unsafe) public static var answer:
        (@Sendable (Notification.Name) -> [AnyHashable: Any]?)?

    nonisolated(unsafe) public static var permissionUsages: @Sendable () -> [PermissionUsage] = {
        PermissionOperationCenter(
            environment: .status(defaults: sharedDefaults)
        ).status()
    }

    nonisolated(unsafe) public static var openURL: @Sendable (URL) -> Bool = {
        NSWorkspace.shared.open($0)
    }

    nonisolated(unsafe) public static var runningApps: @Sendable () -> [RunningAppSnapshot] = {
        RunningAppOperationCenter.liveSnapshots()
    }

    nonisolated(unsafe) public static var homeDirectory: URL =
        FileManager.default.homeDirectoryForCurrentUser

    nonisolated(unsafe) public static var clipboardPasteboard: NSPasteboard = .general
    nonisolated(unsafe) public static var downloadQueueFile: URL = DownloadQueue.file

    nonisolated(unsafe) public static var runAppleScript:
        @Sendable (String, TimeInterval) throws -> String = {
            try AppleScriptHost.execute($0, timeout: $1)
        }

    nonisolated(unsafe) public static var usageRefresh = UsageRefreshDriver.live

    nonisolated(unsafe) public static var verifyAgentHandshake: @Sendable () throws -> AgentHandshake = {
        try AgentClient.shared.verifyHandshake()
    }

    nonisolated(unsafe) public static var performAgentOperation: @Sendable (String) throws -> Data = {
        try AgentClient.shared.performInternal($0)
    }

    nonisolated(unsafe) public static var installTool:
        @Sendable (CLIToolSpec, @escaping @Sendable (String) -> Void) async throws -> String = {
            try await ToolInstaller().install($0, log: $1)
        }

    nonisolated(unsafe) public static var executableNamed: @Sendable (String) -> URL? = {
        CLIToolEnvironment.executable(named: $0)
    }

    nonisolated(unsafe) public static var homebrewClient: @Sendable () -> HomebrewClient = {
        HomebrewClient()
    }

    nonisolated(unsafe) public static var extensionToolReadiness:
        @Sendable (String) async -> ExtensionToolReadiness = { id in
            await ExtensionLifecycleProbeEnvironment.toolReadiness(
                id, executableNamed: CLIEnvironment.executableNamed)
        }

    nonisolated(unsafe) public static var resolveCompanionEndpoint: @Sendable (String?) -> URL = {
        resolvedCompanionEndpoint($0)
    }

    nonisolated(unsafe) public static var companionConfigured: @Sendable () -> Bool = {
        CompanionClient.hasConfiguredEndpointOrDeployment(
            environmentEndpoint: ProcessInfo.processInfo.environment[
                "EDITH_COMPANION_URL"],
            savedEndpoint: sharedDefaults.object(
                forKey: AppStorageKeys.Companion.endpoint) as? String,
            deployment: CompanionDeploymentStore.load())
    }

    public static func resolvedCompanionEndpoint(_ override: String?) -> URL {
        if let override { return CompanionClient.endpoint(override: override) }
        return CompanionClient.endpoint(
            environmentEndpoint: ProcessInfo.processInfo.environment[
                "EDITH_COMPANION_URL"],
            savedEndpoint: sharedDefaults.object(
                forKey: AppStorageKeys.Companion.endpoint) as? String,
            deployment: CompanionDeploymentStore.load())
    }

    nonisolated(unsafe) public static var remoteDirectoryTarget:
        @Sendable (String) async throws -> CLIRemoteDirectoryTarget = {
            try await liveRemoteDirectoryTarget($0)
        }

    nonisolated(unsafe) public static var presentURLs:
        @Sendable ([URL], FilePresentationAction) -> Bool = { urls, action in
            switch action {
            case .open:
                guard let first = urls.first else { return false }
                return NSWorkspace.shared.open(first)
            case .reveal:
                guard !urls.isEmpty else { return false }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
                return true
            }
        }

    nonisolated(unsafe) public static var launchTerminal:
        @Sendable (TerminalLaunchRequest) -> Int32 = { request in
            ForegroundProcess.run(
                executable: URL(fileURLWithPath: request.executable),
                arguments: request.arguments,
                environment: ForegroundProcess.environment(
                    assignments: request.environment, inheriting: true),
                failureNote: "error: could not start the terminal")
        }

    nonisolated(unsafe) static var remoteTransferTarget:
        @Sendable (String) async throws -> CLITransferTarget = { query in
            let runner = try await MachineResolver.runner(query)
            return CLITransferTarget(
                machine: runner.machine,
                endpoint: .remote(machine: runner.machine, connection: runner.ssh))
        }

    private static func detectedInstalledAppURL() -> URL? {
        let starts = [
            Bundle.main.bundleURL,
            Bundle.main.executableURL,
            CommandLine.arguments.first.map { URL(fileURLWithPath: $0) },
        ].compactMap { $0 }
        for start in starts {
            var candidate: URL? = start.resolvingSymlinksInPath()
            for _ in 0..<6 {
                guard let current = candidate else { break }
                if current.pathExtension == "app",
                    FileManager.default.fileExists(atPath: current.path)
                {
                    return current
                }
                candidate =
                    current.pathComponents.count > 1 ? current.deletingLastPathComponent() : nil
            }
        }
        let standard = URL(fileURLWithPath: "/Applications/Edith.app")
        return FileManager.default.fileExists(atPath: standard.path) ? standard : nil
    }

    nonisolated(unsafe) public static var appInspectionCenter: @Sendable () -> AppInspectionCenter =
        {
            AppInspectionCenter()
        }

    nonisolated(unsafe) public static var appContributors: @Sendable () -> [Contributor] = {
        Contributors.cached()
    }

    nonisolated(unsafe) public static var installedAppURL: @Sendable () -> URL? = {
        detectedInstalledAppURL()
    }

    nonisolated(unsafe) public static var updateHistoryURL: @Sendable () -> URL = {
        UpdateCheckLog.url
    }

    public static func reset() {
        sharedDefaults = SharedDefaults.store
        standardDefaults = .standard
        isHelperRunning = {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: AppBridge.helperBundleID
            ).isEmpty
        }
        isMainAppRunning = {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: AppBridge.mainBundleID
            ).isEmpty
        }
        deliver = { IPC.post($0, userInfo: $1) }
        homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        clipboardPasteboard = .general
        downloadQueueFile = DownloadQueue.file
        ClipboardPaths.root = AppData.supportDir
        MachinePaths.root = AppData.supportDir
        ShelfIndex.root = AppData.supportDir.appendingPathComponent("Shelf")
        answer = nil
        permissionUsages = {
            PermissionOperationCenter(
                environment: .status(defaults: sharedDefaults)
            ).status()
        }
        openURL = { NSWorkspace.shared.open($0) }
        runningApps = { RunningAppOperationCenter.liveSnapshots() }
        runAppleScript = { try AppleScriptHost.execute($0, timeout: $1) }
        usageRefresh = UsageRefreshDriver.live
        verifyAgentHandshake = { try AgentClient.shared.verifyHandshake() }
        performAgentOperation = { try AgentClient.shared.performInternal($0) }
        installTool = { try await ToolInstaller().install($0, log: $1) }
        executableNamed = { CLIToolEnvironment.executable(named: $0) }
        homebrewClient = { HomebrewClient() }
        extensionToolReadiness = { id in
            await ExtensionLifecycleProbeEnvironment.toolReadiness(
                id, executableNamed: CLIEnvironment.executableNamed)
        }
        resolveCompanionEndpoint = { resolvedCompanionEndpoint($0) }
        companionConfigured = {
            CompanionClient.hasConfiguredEndpointOrDeployment(
                environmentEndpoint: ProcessInfo.processInfo.environment[
                    "EDITH_COMPANION_URL"],
                savedEndpoint: sharedDefaults.object(
                    forKey: AppStorageKeys.Companion.endpoint) as? String,
                deployment: CompanionDeploymentStore.load())
        }
        remoteDirectoryTarget = { try await liveRemoteDirectoryTarget($0) }
        presentURLs = { urls, action in
            switch action {
            case .open:
                guard let first = urls.first else { return false }
                return NSWorkspace.shared.open(first)
            case .reveal:
                guard !urls.isEmpty else { return false }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
                return true
            }
        }
        appInspectionCenter = { AppInspectionCenter() }
        appContributors = { Contributors.cached() }
        installedAppURL = { detectedInstalledAppURL() }
        updateHistoryURL = { UpdateCheckLog.url }
        launchTerminal = { request in
            ForegroundProcess.run(
                executable: URL(fileURLWithPath: request.executable),
                arguments: request.arguments,
                environment: ForegroundProcess.environment(
                    assignments: request.environment, inheriting: true),
                failureNote: "error: could not start the terminal")
        }
        remoteTransferTarget = { query in
            let runner = try await MachineResolver.runner(query)
            return CLITransferTarget(
                machine: runner.machine,
                endpoint: .remote(machine: runner.machine, connection: runner.ssh))
        }
        QuinjetCLIEnvironment.reset()
        DatabaseCLIEnvironment.reset()
    }

    private static func liveRemoteDirectoryTarget(
        _ query: String
    ) async throws -> CLIRemoteDirectoryTarget {
        let runner = try await MachineResolver.runner(query)
        return CLIRemoteDirectoryTarget(
            machine: runner.machine,
            endpoint: .remote(machine: runner.machine, connection: runner.ssh),
            platform: await runner.ssh.remotePlatform ?? .linux)
    }
}
