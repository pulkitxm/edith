import AppKit
import EdithKit
import ServiceManagement

private let helperBundleIdentifier = MainApp.statusBarBundleIdentifier

private let retiredHelperBundleIdentifiers = [
    "com.pulkit.edith.helper", "com.pulkit.edith.statusbar", "com.pulkit.edith.panel",
    "com.pulkit.edith.bar", "com.pulkit.edith.menubar",
]

func launchHelperIfNeeded() async {
    for identifier in retiredHelperBundleIdentifiers {
        guard !Task.isCancelled else { return }
        let retired = SMAppService.loginItem(identifier: identifier)
        if retired.status == .enabled {
            try? await retired.unregister()
        }
    }
    guard !Task.isCancelled else { return }
    let service = SMAppService.loginItem(identifier: helperBundleIdentifier)
    if service.status != .enabled {
        try? service.register()
    }
    let helperURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Library/LoginItems/Edith.app")
    if let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: helperBundleIdentifier
    ).first {
        guard
            shouldRelaunchHelper(
                runningURL: running.bundleURL,
                expectedURL: helperURL,
                launchedAt: running.launchDate,
                installedAt: helperInstalledDate(helperURL)
            )
        else { return }
        await relaunchHelper(at: helperURL, after: running)
        return
    }
    await MainActor.run {
        guard !Task.isCancelled else { return }
        NSWorkspace.shared.openApplication(
            at: helperURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

func shouldRelaunchHelper(
    runningURL: URL?, expectedURL: URL, launchedAt: Date?, installedAt: Date?
) -> Bool {
    let expected = expectedURL.standardizedFileURL.resolvingSymlinksInPath()
    guard runningURL?.standardizedFileURL.resolvingSymlinksInPath() == expected else {
        return true
    }
    guard let launchedAt, let installedAt else { return false }
    return launchedAt < installedAt
}

private func helperInstalledDate(_ helperURL: URL) -> Date? {
    let exec = helperURL.appendingPathComponent("Contents/MacOS/Edith")
    return (try? FileManager.default.attributesOfItem(atPath: exec.path)[.modificationDate])
        as? Date
}

@MainActor
private func relaunchHelper(at url: URL, after process: NSRunningApplication) async {
    guard !Task.isCancelled else { return }
    process.forceTerminate()
    do {
        guard try await HelperTerminationWaiter.wait(isTerminated: { process.isTerminated }) else {
            return
        }
        NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    } catch {}
}

@MainActor
enum HelperTerminationWaiter {
    static func wait(
        timeout: Duration = .seconds(5), interval: Duration = .milliseconds(100),
        isTerminated: () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            try Task.checkCancellation()
            if isTerminated() { return true }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            try await Task.sleep(for: min(interval, remaining))
        }
    }
}
