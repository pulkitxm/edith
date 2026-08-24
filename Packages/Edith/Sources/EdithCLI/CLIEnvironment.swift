import AppKit
import EdithKit
import Foundation

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

    nonisolated(unsafe) public static var isFilesAppRunning: @Sendable () -> Bool = {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: AppBridge.filesBundleID
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

    nonisolated(unsafe) public static var installTool:
        @Sendable (CLIToolSpec, @escaping @Sendable (String) -> Void) async throws -> String = {
            try await ToolInstaller().install($0, log: $1)
        }

    nonisolated(unsafe) public static var executableNamed: @Sendable (String) -> URL? = {
        CLIToolEnvironment.executable(named: $0)
    }

    nonisolated(unsafe) public static var extensionToolReadiness:
        @Sendable (String) async -> ExtensionToolReadiness = { id in
            await ExtensionLifecycleProbeEnvironment.toolReadiness(
                id, executableNamed: CLIEnvironment.executableNamed)
        }

    nonisolated(unsafe) public static var resolveCompanionEndpoint: @Sendable (String?) -> URL = {
        CompanionClient.endpoint(override: $0)
    }

    private static func detectedInstalledAppURL() -> URL? {
        let bundled = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if bundled.pathExtension == "app",
            FileManager.default.fileExists(atPath: bundled.path)
        {
            return bundled
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
        isFilesAppRunning = {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: AppBridge.filesBundleID
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
        installTool = { try await ToolInstaller().install($0, log: $1) }
        executableNamed = { CLIToolEnvironment.executable(named: $0) }
        extensionToolReadiness = { id in
            await ExtensionLifecycleProbeEnvironment.toolReadiness(
                id, executableNamed: CLIEnvironment.executableNamed)
        }
        resolveCompanionEndpoint = { CompanionClient.endpoint(override: $0) }
        appInspectionCenter = { AppInspectionCenter() }
        appContributors = { Contributors.cached() }
        installedAppURL = { detectedInstalledAppURL() }
        updateHistoryURL = { UpdateCheckLog.url }
        QuinjetCLIEnvironment.reset()
    }
}
