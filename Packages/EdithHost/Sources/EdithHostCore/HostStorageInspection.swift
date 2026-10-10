import Darwin
import Foundation

public struct HostStorageTarget: Sendable {
    public let id: String
    public let title: String
    public let url: URL

    public init(id: String, title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }

    public static func defaults(identity: HostIdentity) -> [HostStorageTarget] {
        [
            Self(id: "data", title: "Application data", url: identity.root),
            Self(id: "machines", title: "Machines", url: identity.extensionDirectory("machines")),
            Self(
                id: "clipboard", title: "Clipboard", url: identity.extensionDirectory("clipboard")),
            Self(id: "seo", title: "Site audits", url: identity.extensionDirectory("seo")),
            Self(id: "usage", title: "Usage files", url: identity.extensionDirectory("usage")),
            Self(id: "music", title: "Music", url: identity.extensionDirectory("music")),
            Self(
                id: "caches", title: "Caches", url: identity.root.appendingPathComponent("Caches")),
            Self(id: "logs", title: "Logs", url: identity.root.appendingPathComponent("Logs")),
        ]
    }
}

public enum HostCoreCloud {
    public static func directory(
        identity: HostIdentity,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if identity.development { return identity.root.appendingPathComponent("iCloud") }
        return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Edith")
    }

    public static func available(identity: HostIdentity, directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: (identity.development ? directory : directory.deletingLastPathComponent()).path)
    }
}

public enum HostStorageInspection {
    public static func inspect(
        targets: [HostStorageTarget], cloud: URL,
        maximumEntries: Int = 100_000, duration: TimeInterval = 15,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws
        -> HostStorageSnapshot
    {
        try HostStorageReader(
            maximumEntries: max(1, min(100_000, maximumEntries)),
            duration: duration.isFinite ? max(0.01, min(30, duration)) : 15,
            isCancelled: isCancelled
        )
        .inspect(targets: targets, cloud: cloud, report: { _ in })
    }
}

final class HostStorageReader {
    private let maximumEntries: Int
    private let deadline: ContinuousClock.Instant
    private var visited = 0
    private var issues: [String] = []
    private var targets: [URL] = []
    private var measurements: [URL: Int64] = [:]
    private let fileManager = FileManager.default
    private let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
    ]

    private let isCancelled: @Sendable () -> Bool

    init(
        maximumEntries: Int, duration: TimeInterval,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.maximumEntries = maximumEntries
        self.isCancelled = isCancelled
        deadline = ContinuousClock.now.advanced(by: .seconds(duration))
    }

    private func checkCancelled() throws {
        if isCancelled() { throw CancellationError() }
    }

    func inspect(
        targets: [HostStorageTarget], cloud: URL,
        report: @Sendable (String) -> Void
    ) throws -> HostStorageSnapshot {
        self.targets = targets.map { canonicalURL($0.url) }
        var footprints: [HostStorageFootprint] = []
        for target in targets {
            try checkCancelled()
            report("Inspecting \(target.title)")
            let bytes = try size(target.url)
            footprints.append(
                HostStorageFootprint(
                    id: target.id, title: target.title, url: target.url, bytes: bytes,
                    exists: fileManager.fileExists(atPath: target.url.path)))
        }
        var restore: [HostStorageRestoreEntry] = []
        if fileManager.fileExists(atPath: cloud.path) {
            report("Inspecting backup files")
            do {
                var entries: [URL] = []
                guard
                    let children = fileManager.enumerator(
                        at: cloud, includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles])
                else { throw CocoaError(.fileReadUnknown) }
                for case let child as URL in children {
                    try checkCancelled()
                    children.skipDescendants()
                    entries.append(child)
                    if entries.count > 256 { break }
                }
                for entry in entries.prefix(256).sorted(by: {
                    $0.lastPathComponent < $1.lastPathComponent
                }) {
                    try checkCancelled()
                    restore.append(
                        HostStorageRestoreEntry(
                            name: entry.lastPathComponent, bytes: try size(entry)))
                }
                if entries.count > 256 { issue("Only the first 256 backup entries are shown.") }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issue("The backup directory could not be read.")
            }
        }
        return HostStorageSnapshot(
            collectedAt: Date(), footprints: footprints, restoreEntries: restore, issues: issues)
    }

    private func size(_ source: URL) throws -> Int64 {
        try checkCancelled()
        guard fileManager.fileExists(atPath: source.path) else { return 0 }
        let original = try source.resourceValues(forKeys: keys)
        guard original.isSymbolicLink != true else { return 0 }
        let source = canonicalURL(source)
        if let measured = measurements[source] { return measured }
        let values: URLResourceValues
        do { values = try source.resourceValues(forKeys: keys) } catch {
            issue("Some storage entries could not be read; sizes are partial.")
            return 0
        }
        if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
        guard values.isDirectory == true else { return 0 }
        guard
            let files = fileManager.enumerator(
                at: source, includingPropertiesForKeys: Array(keys), options: [],
                errorHandler: { [self] _, _ in
                    issue("Some storage entries could not be read; sizes are partial.")
                    return true
                })
        else {
            issue("Some storage directories could not be read; sizes are partial.")
            return 0
        }
        var total: Int64 = 0
        let nested = targets.filter { $0.path.hasPrefix(source.path + "/") }
        var nestedSizes = Dictionary(nested.map { ($0, Int64(0)) }, uniquingKeysWith: max)
        for case let file as URL in files {
            try checkCancelled()
            guard visited < maximumEntries, ContinuousClock.now < deadline else {
                issue(
                    "The inspection limit was reached; sizes are partial. Open a folder to inspect it further."
                )
                break
            }
            visited += 1
            do {
                let values = try file.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { files.skipDescendants(); continue }
                guard values.isRegularFile == true else { continue }
                let (sum, overflow) = total.addingReportingOverflow(
                    Int64(max(0, values.fileSize ?? 0)))
                if overflow {
                    issue("The storage total exceeds the supported size range.")
                    return Int64.max
                }
                total = sum
                for target in nested where file == target || file.path.hasPrefix(target.path + "/")
                {
                    let (bytes, overflow) = nestedSizes[target, default: 0].addingReportingOverflow(
                        Int64(max(0, values.fileSize ?? 0)))
                    nestedSizes[target] = overflow ? Int64.max : bytes
                }
            } catch {
                issue("Some storage entries could not be read; sizes are partial.")
            }
        }
        measurements[source] = total
        measurements.merge(nestedSizes, uniquingKeysWith: { _, latest in latest })
        return total
    }

    private func issue(_ message: String) {
        if !issues.contains(message) { issues.append(message) }
    }

    private func canonicalURL(_ url: URL) -> URL {
        guard let path = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }
}
