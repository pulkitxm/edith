import CoreGraphics
import EdithKit
import Foundation
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

    public init(
        runtime: AgentRuntime, hub: AgentHub, scheduler: JobScheduler,
        watchers: [FileSystemWatcher]
    ) {
        self.runtime = runtime
        self.hub = hub
        self.scheduler = scheduler
        self.watchers = watchers
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
        let scheduler = JobScheduler(
            publish: { topic, payload in
                Task { await runtime.publish(topic: topic, payload: payload) }
            },
            power: LivePowerSource(),
            pauseAmbientOnBattery: SharedDefaults.store.bool(
                forKey: AgentSettingsKeys.pauseAmbientOnBattery))
        let hub = AgentHub(runtime: runtime)
        let watcher = FileSystemWatcher(paths: UsageWatchPaths.directories(), debounce: 30) {
            Task { await scheduler.runNow("usage.refresh") }
        }
        watcher.start()
        AgentLog.logger.info(
            "watching \(watcher.watchedPaths.count, privacy: .public) usage paths")
        Task {
            await runtime.attach(scheduler: scheduler)
            await AgentOperations.register(on: runtime, store: store)
            for job in AgentJobCatalog.jobs(store: store, scheduler: scheduler) {
                await scheduler.register(job)
            }
            await scheduler.start()
            if let store {
                let report = try? AttentionEventStore(store: store).importLegacyFiles()
                if let report, !report.alreadyImported, report.events > 0 {
                    AgentLog.logger.info(
                        "imported \(report.events, privacy: .public) attention events")
                }
            }
        }
        hub.resume()
        AgentLog.logger.info("edithd \(build, privacy: .public) listening")
        return AgentServices(runtime: runtime, hub: hub, scheduler: scheduler, watchers: [watcher])
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
        guard
            let output = try? Shell.capture(
                "/usr/bin/pmset", arguments: ["-g", "batt"])
        else { return false }
        return output.contains("Battery Power")
    }

    static func isScreenLocked() -> Bool {
        guard
            let session = CGSessionCopyCurrentDictionary() as? [String: Any],
            let locked = session["CGSSessionScreenIsLocked"] as? Int
        else { return false }
        return locked == 1
    }
}

enum Shell {
    static func capture(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
