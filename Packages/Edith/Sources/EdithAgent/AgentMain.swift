import CoreGraphics
import EdithKit
import Foundation
import IOKit.ps
import os

public enum AgentLog {
    public static let subsystem = "com.pulkit.edith.agent"
    public static let logger = Logger(subsystem: subsystem, category: "runtime")
}

public struct AgentServices {
    public let runtime: AgentRuntime
    public let hub: AgentHub
    public let scheduler: JobScheduler
    public let watchers: [FileSystemWatcher]
    private let startup: Task<Void, Never>?

    public init(
        runtime: AgentRuntime, hub: AgentHub, scheduler: JobScheduler,
        watchers: [FileSystemWatcher], startup: Task<Void, Never>? = nil
    ) {
        self.runtime = runtime
        self.hub = hub
        self.scheduler = scheduler
        self.watchers = watchers
        self.startup = startup
    }

    public func stop() async {
        startup?.cancel()
        watchers.forEach { $0.stop() }
        async let runtimeStopped: Void = runtime.shutdown()
        async let schedulerStopped: Void = scheduler.shutdown()
        await startup?.value
        _ = await (runtimeStopped, schedulerStopped)
    }
}

public enum AgentBoot {
    public static func build() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? ProcessInfo.processInfo.environment["EDITH_AGENT_BUILD"] ?? "development"
    }

    public static func makeStore(build: String) -> AgentStore? {
        do {
            return try AgentStore(url: AgentStoreLayout.storeURL(), build: build)
        } catch {
            AgentLog.logger.error(
                "store unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public static func start() -> AgentServices {
        let build = build()
        let store = makeStore(build: build)
        let runtime = AgentRuntime(build: build, store: store)
        let downloads = DownloadWorker(
            publish: { snapshot in
                if let payload = try? AgentPayload.encode(snapshot) {
                    await runtime.publish(topic: .downloads, payload: payload)
                }
            },
            completed: { IPC.post(IPC.Name.musicFolderChanged) })
        let scheduler = JobScheduler(
            publish: { topic, payload in
                Task { await runtime.publish(topic: topic, payload: payload) }
            },
            power: LivePowerSource(),
            pauseAmbientOnBattery: SharedDefaults.store.bool(
                forKey: AgentSettingsKeys.pauseAmbientOnBattery),
            observe: { await runtime.record($0) })
        let hub = AgentHub(runtime: runtime)
        let watcher = FileSystemWatcher(paths: UsageWatchPaths.directories(), debounce: 30) {
            Task { await scheduler.runNow("usage.refresh") }
        }
        watcher.start()
        AgentLog.logger.info(
            "watching \(watcher.watchedPaths.count, privacy: .public) usage paths")
        let startup = Task {
            guard !Task.isCancelled else { return }
            await runtime.attach(scheduler: scheduler)
            let metrics = await AgentMachineMetricsService()
            await metrics.register(on: runtime)
            await AgentOperations.register(
                on: runtime, store: store, scheduler: scheduler, downloads: downloads)
            do {
                let tasks = try AgentTaskService(
                    publish: { snapshots in
                        if let payload = try? AgentPayload.encode(snapshots) {
                            await runtime.publish(topic: .tasks, payload: payload)
                        }
                    }, record: { await runtime.record($0) })
                await tasks.registerCommand()
                await AgentMachineOperations.register(on: tasks)
                await downloads.registerEstimate(on: tasks)
                await AgentTaskOperations.register(on: runtime, service: tasks)
            } catch {
                await runtime.record(
                    AgentEvent(
                        level: .error, category: "runtime", name: "tasks",
                        message: error.localizedDescription))
            }
            guard !Task.isCancelled, await !runtime.isShuttingDown else { return }
            do { try await downloads.start() } catch {
                await runtime.record(
                    AgentEvent(
                        level: .error, category: "download", name: "startup",
                        message: error.localizedDescription))
            }
            for job in AgentJobCatalog.jobs(
                store: store, scheduler: scheduler, downloads: downloads)
            {
                await scheduler.register(job)
            }
            await scheduler.start()
            guard !Task.isCancelled, await !runtime.isShuttingDown else { return }
            hub.resume()
            await runtime.record(
                AgentEvent(
                    category: "runtime", name: "startup", message: "Background services ready"))
            if let store {
                let report = try? AttentionEventStore(store: store).importLegacyFiles()
                if let report, !report.alreadyImported, report.events > 0 {
                    AgentLog.logger.info(
                        "imported \(report.events, privacy: .public) attention events")
                }
            }
        }
        _ = IPC.observe(IPC.Name.settingsChanged) {
            Task {
                await downloads.refresh()
                await scheduler.setPauseAmbientOnBattery(
                    SharedDefaults.store.bool(
                        forKey: AgentSettingsKeys.pauseAmbientOnBattery))
            }
        }
        return AgentServices(
            runtime: runtime, hub: hub, scheduler: scheduler, watchers: [watcher], startup: startup)
    }
}

public struct LivePowerSource: AgentPowerSource {
    public init() {}

    public var isOnBattery: Bool {
        PowerState.isOnBattery()
    }

    public var isScreenLocked: Bool {
        PowerState.isScreenLocked()
    }
}

enum PowerState {
    static func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        return IOPSGetProvidingPowerSourceType(snapshot).takeRetainedValue()
            as String == kIOPMBatteryPowerKey
    }

    static func isScreenLocked() -> Bool {
        guard
            let session = CGSessionCopyCurrentDictionary() as? [String: Any],
            let locked = session["CGSSessionScreenIsLocked"] as? Int
        else { return false }
        return locked == 1
    }
}
