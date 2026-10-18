import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostCoreBackgroundPolicyTests {
    @Test func persistedPolicyActuallyControlsAmbientBackupWithoutChangingTheOwnedPID() async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = try HostCoreRuntime(identity: fixture.identity)
        let controller = fixture.controller()
        let scheduler = HostSettingsScheduler(
            signature: { Data("synthetic".utf8) }, enabled: { true }, onBattery: { true },
            pauseAmbientOnBattery: {
                fixture.defaults.bool(forKey: HostCoreBackgroundPolicy.preferenceKey)
            },
            power: .any,
            run: {
                let result = try await runtime.synchronizeSettings()
                return result.settingsBackup?.exported == true
            })
        let initial = try await controller.read()
        #expect(initial.processIdentifier == fixture.process.processIdentifier)
        #expect(!initial.pauseAmbientOnBattery)
        let paused = try await controller.set(pauseAmbientOnBattery: true)
        await scheduler.runIfNeeded()
        #expect(runtime.snapshot().agent?.jobs.first { $0.id == "backup.sync" }?.runCount == 0)
        let reopened = try #require(UserDefaults(suiteName: fixture.identity.identifier))
        #expect(reopened.bool(forKey: HostCoreBackgroundPolicy.preferenceKey))
        let resumed = try await controller.set(pauseAmbientOnBattery: false)
        await scheduler.runIfNeeded()
        let job = try #require(runtime.snapshot().agent?.jobs.first { $0.id == "backup.sync" })
        #expect(job.runCount == 1 && job.phase == .idle)
        #expect(runtime.snapshot().settingsBackup?.exported == true)
        #expect(
            FileManager.default.fileExists(
                atPath: runtime.snapshot().cloudDirectory.appendingPathComponent("settings.json")
                    .path))
        #expect(paused.processIdentifier == resumed.processIdentifier)
        #expect(fixture.process.isRunning && fixture.notifications == 2)
        await scheduler.shutdown()
        await runtime.shutdown()
    }

    @Test func perJobBatteryRestrictionRemainsAndLiveSubscribersKeepTheirAdaptiveWork() async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.controller().set(pauseAmbientOnBattery: false)
        var fixedRuns = 0
        let fixed = HostSettingsScheduler(
            signature: { Data("fixed".utf8) }, enabled: { true }, onBattery: { true },
            pauseAmbientOnBattery: {
                fixture.defaults.bool(forKey: HostCoreBackgroundPolicy.preferenceKey)
            },
            power: .pauseOnBattery,
            run: {
                fixedRuns += 1; return true
            })
        await fixed.runIfNeeded()
        #expect(fixedRuns == 0)
        _ = try await fixture.controller().set(pauseAmbientOnBattery: true)
        var liveRuns = 0
        let live = HostSettingsScheduler(
            signature: { Data("live".utf8) }, enabled: { true }, onBattery: { true },
            pauseAmbientOnBattery: {
                fixture.defaults.bool(forKey: HostCoreBackgroundPolicy.preferenceKey)
            },
            power: .any, subscribers: { 1 },
            run: {
                liveRuns += 1; return true
            })
        await live.runIfNeeded()
        #expect(liveRuns == 1)
        await fixed.shutdown(); await live.shutdown()
    }

    @Test func staleCancelledAndOfflineChangesNeverWriteOrNotify() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pid = fixture.process.processIdentifier
        let stale = fixture.controller(refresh: {
            fixture.selectedPID = nil; return pid
        })
        await #expect(throws: HostCoreCommandFailure.self) {
            try await stale.set(pauseAmbientOnBattery: true)
        }
        #expect(fixture.defaults.object(forKey: HostCoreBackgroundPolicy.preferenceKey) == nil)
        fixture.selectedPID = pid
        let cancelled = fixture.controller(refresh: {
            withUnsafeCurrentTask { $0?.cancel() }
            return pid
        })
        let task = Task { try await cancelled.set(pauseAmbientOnBattery: true) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.defaults.object(forKey: HostCoreBackgroundPolicy.preferenceKey) == nil)
        fixture.selectedPID = nil
        await #expect(throws: HostCoreCommandFailure.self) {
            try await fixture.controller().set(pauseAmbientOnBattery: true)
        }
        #expect(fixture.notifications == 0 && fixture.process.isRunning)
    }

    @Test func powerPolicyChangesDoNotCancelAnAlreadyRunningOwnedBackup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        let started = Signal()
        let release = Signal()
        var completed = false
        let scheduler = HostSettingsScheduler(
            signature: { Data("synthetic".utf8) }, enabled: { true }, onBattery: { true },
            pauseAmbientOnBattery: {
                fixture.defaults.bool(forKey: HostCoreBackgroundPolicy.preferenceKey)
            },
            power: .any,
            run: {
                await started.open()
                await release.wait()
                try Task.checkCancellation()
                completed = true
                return true
            })
        let running = Task { await scheduler.runIfNeeded() }
        await started.wait()
        _ = try await controller.set(pauseAmbientOnBattery: true)
        scheduler.preferencesChanged()
        await release.open()
        await running.value
        #expect(completed && fixture.process.isRunning)
        await scheduler.shutdown()
    }

    @Test func originalConfigKeyUsesFalseDefaultAndNotifiesActualOwner() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let config = try HostConfigurationCLI(
            shared: fixture.defaults, standard: fixture.defaults,
            changed: { fixture.notifications += 1 })
        #expect(
            try config.execute(["get", HostCoreBackgroundPolicy.preferenceKey]).stdout == "false\n")
        #expect(
            try config.execute(["set", HostCoreBackgroundPolicy.preferenceKey, "true"]).exitCode
                == 0)
        #expect(fixture.defaults.bool(forKey: HostCoreBackgroundPolicy.preferenceKey))
        #expect(fixture.notifications == 1)
        _ = try config.execute(["unset", HostCoreBackgroundPolicy.preferenceKey])
        #expect(!fixture.defaults.bool(forKey: HostCoreBackgroundPolicy.preferenceKey))
        #expect(fixture.notifications == 2)
    }

    @MainActor private final class Fixture {
        let directory: URL
        let identity: HostIdentity
        let defaults: UserDefaults
        let process = Process()
        var selectedPID: Int32?
        var notifications = 0

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "core-power-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.power-" + UUID().uuidString,
                supportDirectory: directory)
            defaults = try #require(
                SharedDefaults.applicationStore(identifier: identity.identifier))
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["120"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            selectedPID = process.processIdentifier
            try JSONEncoder().encode(ExtensionProcessIdentity.read(process.processIdentifier))
                .write(to: directory.appendingPathComponent("owned-process.json"), options: .atomic)
        }

        func controller(refresh: (@MainActor () async throws -> Int32)? = nil)
            -> HostCoreBackgroundPolicyControl
        {
            HostCoreBackgroundPolicyControl(
                defaults: defaults, processIdentifier: { self.selectedPID },
                refresh: refresh ?? { self.process.processIdentifier },
                changed: { self.notifications += 1 })
        }

        func remove() {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            defaults.removePersistentDomain(forName: identity.identifier)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private actor Signal {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if !opened { await withCheckedContinuation { waiters.append($0) } }
        }
        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
}
