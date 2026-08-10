import AppKit
import EdithKit
import Foundation

public enum EdithProcesses {
    public static var running: [NSRunningApplication] {
        [AppBridge.mainBundleID, AppBridge.helperBundleID].flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }
    }

    public static func quitAll(within seconds: TimeInterval) async -> Bool {
        var pending = running
        guard !pending.isEmpty else { return true }
        for app in pending { app.terminate() }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            pending = running.filter { !$0.isTerminated }
            if pending.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(120))
        }
        for app in pending where !app.isTerminated { app.forceTerminate() }
        let hardDeadline = Date().addingTimeInterval(3)
        while Date() < hardDeadline {
            if running.filter({ !$0.isTerminated }).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return running.filter { !$0.isTerminated }.isEmpty
    }

    public static func launch(_ bundle: URL, arguments: [String] = []) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !arguments.isEmpty
        configuration.createsNewApplicationInstance = arguments.isEmpty
        configuration.arguments = arguments
        _ = try await NSWorkspace.shared.openApplication(
            at: bundle, configuration: configuration)
    }
}
