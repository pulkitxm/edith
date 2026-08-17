import AppKit
import EdithKit
import Foundation

public enum CLIEnvironment {
    nonisolated(unsafe) public static var sharedDefaults: UserDefaults = SharedDefaults.store
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
        PermissionsStatus.usages
    }

    nonisolated(unsafe) public static var homeDirectory: URL =
        FileManager.default.homeDirectoryForCurrentUser

    nonisolated(unsafe) public static var clipboardPasteboard: NSPasteboard = .general

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

    nonisolated(unsafe) public static var resolveCompanionEndpoint: @Sendable (String?) -> URL = {
        CompanionClient.endpoint(override: $0)
    }

    nonisolated(unsafe) public static var installedAppURL: @Sendable () -> URL? = {
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
        ClipboardPaths.root = AppData.supportDir
        MachinePaths.root = AppData.supportDir
        ShelfIndex.root = AppData.supportDir.appendingPathComponent("Shelf")
        answer = nil
        permissionUsages = { PermissionsStatus.usages }
        runAppleScript = { try AppleScriptHost.execute($0, timeout: $1) }
        usageRefresh = UsageRefreshDriver.live
        installTool = { try await ToolInstaller().install($0, log: $1) }
        executableNamed = { CLIToolEnvironment.executable(named: $0) }
        resolveCompanionEndpoint = { CompanionClient.endpoint(override: $0) }
    }
}
