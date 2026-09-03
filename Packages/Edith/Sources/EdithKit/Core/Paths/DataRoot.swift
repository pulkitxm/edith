import EdithCore
import Foundation

public enum DataRoot {
    public static let devOverrideVariable = "EDITH_DATA_ROOT"
    public static let logRetention: TimeInterval = 7 * 24 * 60 * 60

    public static var support: URL {
        if let override = ProcessInfo.processInfo.environment[devOverrideVariable],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return AppDirectories.current.data
    }

    public static var caches: URL { AppDirectories.current.cache }

    public static var runtime: URL { AppDirectories.current.runtime }

    public static var logs: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Edith")
    }

    public static var machines: URL { support.appendingPathComponent("machines") }

    public static var clipboard: URL { support.appendingPathComponent("clipboard") }

    public static var siteAudit: URL { support.appendingPathComponent("seo") }

    public static var settingsExport: URL { support.appendingPathComponent("settings.json") }

    public static var music: URL { support.appendingPathComponent("music") }

    public static var usage: URL { support.appendingPathComponent("data") }

    public static func prepare(fileManager: FileManager = .default) {
        for directory in [support, caches, runtime, logs] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public static func expiredLogs(
        in names: [String], now: Date, ages: [String: Date]
    ) -> [String] {
        names.filter { name in
            guard let written = ages[name] else { return false }
            return now.timeIntervalSince(written) > logRetention
        }
    }

    public static func pruneLogs(fileManager: FileManager = .default, now: Date = Date()) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: logs.path) else { return }
        var ages: [String: Date] = [:]
        for name in names {
            let candidate = logs.appendingPathComponent(name)
            guard
                let written = (try? fileManager.attributesOfItem(atPath: candidate.path))?[
                    .modificationDate] as? Date
            else { continue }
            ages[name] = written
        }
        for name in expiredLogs(in: names, now: now, ages: ages) {
            try? fileManager.removeItem(at: logs.appendingPathComponent(name))
        }
    }
}
