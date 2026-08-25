import Foundation
import Testing

@testable import EdithKit
@testable import EdithHelper

private final class LidAwakeCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private final class LidAwakeThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var ranOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        value = Thread.isMainThread
        lock.unlock()
    }
}

private func lidAwakeProcessesExit(_ processIDs: [pid_t], timeout: TimeInterval = 1) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        let running = processIDs.contains { processID in
            kill(processID, 0) == 0 || errno == EPERM
        }
        if !running { return true }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return false
}

private func lidAwakeProcessIDs(at url: URL) throws -> [pid_t] {
    try String(contentsOf: url, encoding: .utf8)
        .split(separator: " ")
        .compactMap { pid_t($0) }
}

@Suite struct LidAwakeTests {
    @Test func commandTogglesTheLidCloseSleepPathway() {
        #expect(LidAwakeCommand.arguments(active: true) == ["-a", "disablesleep", "1"])
        #expect(LidAwakeCommand.arguments(active: false) == ["-a", "disablesleep", "0"])
        #expect(LidAwakeCommand.shellCommand(active: true) == "/usr/bin/pmset -a disablesleep 1")
    }

    @Test func unavailableHelperErrorsGiveTheCorrectRecovery() {
        let approval = LidAwakePrivilegedClientError.helperUnavailable(.awaitingApproval)
        #expect(
            approval.errorDescription?.contains("System Settings > General > Login Items") == true)
        let missing = LidAwakePrivilegedClientError.helperUnavailable(.notFound)
        #expect(missing.errorDescription?.contains("Reinstall Edith") == true)
        let registration = LidAwakePrivilegedClientError.helperUnavailable(.notRegistered)
        #expect(registration.errorDescription?.contains("Reopen Edith") == true)
        #expect(
            LidAwakePrivilegedClientError.timedOut.errorDescription?.contains("did not answer")
                == true)
    }

    @Test func privilegedReplyTimesOutAndCancelsTheConnection() async {
        let reply = LidAwakePrivilegedReply()
        let probe = LidAwakeCancellationProbe()

        await #expect(throws: LidAwakePrivilegedClientError.self) {
            try await reply.wait(
                timeout: .milliseconds(20), cancel: { probe.record() }, send: { _ in })
        }
        #expect(probe.count == 1)
    }

    @Test func privilegedReplyCancellationFinishesImmediately() async {
        let reply = LidAwakePrivilegedReply()
        let probe = LidAwakeCancellationProbe()
        let task = Task {
            try await reply.wait(
                timeout: .seconds(10), cancel: { probe.record() }, send: { _ in })
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(probe.count == 1)
    }

    @Test func privilegedCommandKillsATermIgnoringProcessAtTheDeadline() throws {
        let started = Date()

        let result = try LidAwakeCommandProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.05,
            terminationGrace: 0.05, pollInterval: 0.005)

        #expect(result.timedOut)
        #expect(!result.cancelled)
        #expect(result.terminationStatus != 0)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func privilegedCommandKillsTheIsolatedProcessGroupAtTheDeadline() throws {
        let processIDsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lid-awake-processes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: processIDsURL) }
        let script = """
            trap '' TERM
            (trap '' TERM; while :; do sleep 1; done) &
            printf '%s %s' "$$" "$!" > "$1"
            while :; do sleep 1; done
            """

        let result = try LidAwakeCommandProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "lid-awake", processIDsURL.path], timeout: 0.05,
            terminationGrace: 0.05, pollInterval: 0.005)
        let processIDs = try lidAwakeProcessIDs(at: processIDsURL)

        #expect(result.timedOut)
        #expect(!result.cancelled)
        #expect(processIDs.count == 2)
        #expect(lidAwakeProcessesExit(processIDs))
    }

    @Test func privilegedCommandCancellationKillsTheIsolatedProcessGroup() throws {
        let processIDsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lid-awake-cancelled-processes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: processIDsURL) }
        let script = """
            trap '' TERM
            (trap '' TERM; while :; do sleep 1; done) &
            printf '%s %s' "$$" "$!" > "$1"
            while :; do sleep 1; done
            """

        let result = try LidAwakeCommandProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "lid-awake", processIDsURL.path], timeout: 5,
            terminationGrace: 0.05, pollInterval: 0.005,
            cancelled: { FileManager.default.fileExists(atPath: processIDsURL.path) })
        let processIDs = try lidAwakeProcessIDs(at: processIDsURL)

        #expect(!result.timedOut)
        #expect(result.cancelled)
        #expect(processIDs.count == 2)
        #expect(lidAwakeProcessesExit(processIDs))
    }

    @Test func privilegedCommandCapturesFailureWithoutTimingOut() throws {
        let result = try LidAwakeCommandProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf refused >&2; exit 7"], timeout: 1)

        #expect(!result.timedOut)
        #expect(!result.cancelled)
        #expect(result.terminationStatus == 7)
        #expect(result.standardError == "refused")
    }

    @Test func systemStateReadIsBoundedWhenTheProcessStalls() async {
        let started = Date()

        await #expect(throws: LidAwakeSystemStateReadError.self) {
            try await LidAwakeSystemStateReader.read(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.05)
        }

        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func systemStateReadRunsTheProcessOffTheMainThread() async throws {
        let probe = LidAwakeThreadProbe()
        let active = try await LidAwakeSystemStateReader.read(
            executableURL: URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["-g"], timeout: 1,
            runner: { _, _, _, _ in
                probe.record()
                return LidAwakeCommandProcessResult(
                    terminationStatus: 0,
                    standardOutput: "System-wide power settings:\n SleepDisabled 1\n",
                    standardError: "", timedOut: false, cancelled: false)
            })

        #expect(active)
        #expect(probe.ranOnMainThread == false)
    }

    @Test func systemStateReadRejectsMissingSleepDisabledState() async {
        await #expect(throws: LidAwakeSystemStateReadError.malformedOutput) {
            try await LidAwakeSystemStateReader.read(
                executableURL: URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["-g"],
                timeout: 1,
                runner: { _, _, _, _ in
                    LidAwakeCommandProcessResult(
                        terminationStatus: 0,
                        standardOutput: "Currently in use:\n standby 1\n", standardError: "",
                        timedOut: false, cancelled: false)
                })
        }
    }

    @Test func daemonIsPackagedInsideItsCallingApp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = root.appendingPathComponent("Resources/com.pulkit.edith.lidawake.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any])
        #expect(
            plist["BundleProgram"] as? String
                == "Contents/Library/PrivilegedHelperTools/com.pulkit.edith.lidawake")
        let associated = plist["AssociatedBundleIdentifiers"] as? [String]
        #expect(
            associated?.contains(LidAwakePrivilegedService.clientBundleIdentifier) == true)
        let build = try String(
            contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        #expect(
            build.contains(
                "PRIVILEGED_HELPER=\"$HELPER/Contents/Library/PrivilegedHelperTools/com.pulkit.edith.lidawake\""
            ))
        #expect(
            build.contains(
                "LAUNCH_DAEMONS=\"$HELPER/Contents/Library/LaunchDaemons\""))
    }

    @Test func powerSettingsReportSleepDisabled() {
        let on = """
            System-wide power settings:
             SleepDisabled		1
            Currently in use:
             standby              1
            """
        let off = """
            System-wide power settings:
             SleepDisabled		0
            Currently in use:
             standby              1
            """
        #expect(LidAwakeCommand.sleepDisabled(inPowerSettings: on))
        #expect(!LidAwakeCommand.sleepDisabled(inPowerSettings: off))
        #expect(!LidAwakeCommand.sleepDisabled(inPowerSettings: "Currently in use:\n standby 1"))
        #expect(!LidAwakeCommand.sleepDisabled(inPowerSettings: ""))
    }

    @Test func installedAndActiveAreSeparateState() {
        #expect(LidAwakeState.enabledKey != LidAwakeState.activeKey)
        let defaults = UserDefaults(suiteName: "test.lidawake")!
        defaults.removePersistentDomain(forName: "test.lidawake")
        defer { defaults.removePersistentDomain(forName: "test.lidawake") }

        defaults.set(true, forKey: LidAwakeState.enabledKey)
        #expect(LidAwakeState.isEnabled(defaults))
        #expect(!LidAwakeState.isActive(defaults))

        LidAwakeState.setActive(true, defaults)
        #expect(LidAwakeState.isActive(defaults))

        LidAwakeState.setActive(false, defaults)
        #expect(!LidAwakeState.isActive(defaults))
        #expect(LidAwakeState.isEnabled(defaults), "closing the lid again must keep it installed")
    }

    @Test func inactiveWhenTheExtensionIsOff() {
        let defaults = UserDefaults(suiteName: "test.lidawake.off")!
        defaults.removePersistentDomain(forName: "test.lidawake.off")
        defer { defaults.removePersistentDomain(forName: "test.lidawake.off") }

        defaults.set(true, forKey: LidAwakeState.activeKey)
        #expect(!LidAwakeState.isActive(defaults))
    }

    @Test func sleepIsRestoredOnQuitUnlessTurnedOff() {
        let defaults = UserDefaults(suiteName: "test.lidawake.quit")!
        defaults.removePersistentDomain(forName: "test.lidawake.quit")
        defer { defaults.removePersistentDomain(forName: "test.lidawake.quit") }

        #expect(LidAwakeState.restoresOnQuit(defaults))
        defaults.set(false, forKey: LidAwakeState.restoreOnQuitKey)
        #expect(!LidAwakeState.restoresOnQuit(defaults))
    }

    @Test func batteryPolicySuspendsBelowThresholdAndResumesOnAC() {
        #expect(
            LidAwakeBatteryPolicy.decide(
                intent: true, suspended: false, percent: 9, onAC: false, threshold: 10)
                == .suspend)
        #expect(
            LidAwakeBatteryPolicy.decide(
                intent: true, suspended: true, percent: 14, onAC: true, threshold: 10)
                == .none)
        #expect(
            LidAwakeBatteryPolicy.decide(
                intent: true, suspended: true, percent: 15, onAC: true, threshold: 10)
                == .resume)
        #expect(
            LidAwakeBatteryPolicy.decide(
                intent: true, suspended: true, percent: 100, onAC: true, threshold: 98)
                == .resume)
    }

    @Test func batteryThresholdIsBoundedAcrossStoredAndConfigurationReads() throws {
        let suite = "test.lidawake.battery.range.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(140, forKey: LidAwakeState.batteryThresholdKey)

        #expect(LidAwakeState.batteryThreshold(defaults) == 100)

        let executor = ConfigurationExecutor(
            shared: defaults, standard: defaults, announceChange: {})
        #expect(throws: ConfigurationError.self) {
            try executor.set(.int(-1), forKey: LidAwakeState.batteryThresholdKey)
        }
        #expect(throws: ConfigurationError.self) {
            try executor.set(.int(101), forKey: LidAwakeState.batteryThresholdKey)
        }
        try executor.set(.int(100), forKey: LidAwakeState.batteryThresholdKey)
        #expect(defaults.integer(forKey: LidAwakeState.batteryThresholdKey) == 100)
    }

    @Test func settingsBackupRejectsMalformedBatteryThresholds() {
        #expect(settingsBackupLidAwakeBatteryThreshold(0) == 0)
        #expect(settingsBackupLidAwakeBatteryThreshold(100) == 100)
        #expect(settingsBackupLidAwakeBatteryThreshold(-1) == nil)
        #expect(settingsBackupLidAwakeBatteryThreshold(101) == nil)
        #expect(settingsBackupLidAwakeBatteryThreshold(20.5) == nil)
        #expect(settingsBackupLidAwakeBatteryThreshold(true) == nil)
        #expect(settingsBackupLidAwakeBatteryThreshold(Double.greatestFiniteMagnitude) == nil)
    }

    @Test func batteryOverrideLastsUntilAC() {
        #expect(LidAwakeBatteryPolicy.shouldKeepOverride(true, onAC: false))
        #expect(!LidAwakeBatteryPolicy.shouldKeepOverride(true, onAC: true))
        #expect(!LidAwakeBatteryPolicy.shouldKeepOverride(false, onAC: false))
    }

    @Test func lidSessionEndsAfterCloseAndReopen() {
        var tracker = LidAwakeLidSessionTracker()
        tracker.start(lidClosed: false)
        #expect(tracker.isActive)
        let remainedOpen = tracker.handle(lidClosed: false)
        #expect(!remainedOpen)
        let startedSession = tracker.handle(lidClosed: true)
        #expect(!startedSession)
        let endedSession = tracker.handle(lidClosed: false)
        #expect(endedSession)
        #expect(!tracker.isActive)
    }

    @Test func lidSessionStartedWithClosedLidWaitsForReopen() {
        var tracker = LidAwakeLidSessionTracker()
        tracker.start(lidClosed: true)
        let remainedClosed = tracker.handle(lidClosed: true)
        #expect(!remainedClosed)
        let endedSession = tracker.handle(lidClosed: false)
        #expect(endedSession)
    }
}
