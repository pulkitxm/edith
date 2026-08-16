import Foundation

public struct JunkItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let path: URL
    public var sizeBytes: Int64
    public var selected: Bool

    public init(id: String, name: String, path: URL, sizeBytes: Int64, selected: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.sizeBytes = sizeBytes
        self.selected = selected
    }
}

public enum JunkSelection: Sendable {
    case all, none, some
}

public struct JunkCategory: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public var items: [JunkItem]

    public init(id: String, name: String, detail: String, items: [JunkItem]) {
        self.id = id
        self.name = name
        self.detail = detail
        self.items = items
    }

    public var sizeBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    public var selectedBytes: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.sizeBytes } }

    public var selection: JunkSelection {
        let selected = items.filter(\.selected).count
        if selected == 0 { return .none }
        if selected == items.count { return .all }
        return .some
    }
}

public struct DriveInfo: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let totalBytes: Int64
    public let isRemovable: Bool
    public let isInternal: Bool

    public init(
        id: String, name: String, totalBytes: Int64, isRemovable: Bool, isInternal: Bool
    ) {
        self.id = id
        self.name = name
        self.totalBytes = totalBytes
        self.isRemovable = isRemovable
        self.isInternal = isInternal
    }

    public var isExternal: Bool { isRemovable || !isInternal }
}

public enum JunkCatalog {
    public struct Entry: Sendable {
        public let id: String
        public let name: String
        public let detail: String
        public let relativePaths: [String]
        public let defaultOn: Bool

        public init(
            id: String, name: String, detail: String, relativePaths: [String], defaultOn: Bool
        ) {
            self.id = id
            self.name = name
            self.detail = detail
            self.relativePaths = relativePaths
            self.defaultOn = defaultOn
        }
    }

    public static let entries: [Entry] = [
        Entry(
            id: "derivedData", name: "Xcode DerivedData",
            detail: "Build intermediates, rebuilt on next build.",
            relativePaths: ["Library/Developer/Xcode/DerivedData"], defaultOn: true),
        Entry(
            id: "swiftpm", name: "Swift Package cache",
            detail: "Cached package checkouts, re-fetched on demand.",
            relativePaths: ["Library/Caches/org.swift.swiftpm"], defaultOn: true),
        Entry(
            id: "npm", name: "npm cache",
            detail: "Tarball cache, re-downloaded on install.",
            relativePaths: [".npm/_cacache"], defaultOn: true),
        Entry(
            id: "yarn", name: "Yarn cache", detail: "Re-downloaded on install.",
            relativePaths: ["Library/Caches/Yarn"], defaultOn: true),
        Entry(
            id: "bun", name: "Bun cache", detail: "Re-downloaded on install.",
            relativePaths: [".bun/install/cache"], defaultOn: true),
        Entry(
            id: "pip", name: "pip cache", detail: "Wheel cache, re-downloaded on install.",
            relativePaths: ["Library/Caches/pip"], defaultOn: true),
        Entry(
            id: "homebrew", name: "Homebrew cache", detail: "Downloaded bottles.",
            relativePaths: ["Library/Caches/Homebrew"], defaultOn: true),
        Entry(
            id: "playwright", name: "Playwright browsers",
            detail: "Re-downloaded on next test run.",
            relativePaths: ["Library/Caches/ms-playwright"], defaultOn: false),
        Entry(
            id: "puppeteer", name: "Puppeteer cache", detail: "Re-downloaded on next run.",
            relativePaths: [".cache/puppeteer"], defaultOn: false),
        Entry(
            id: "claudeCode", name: "Claude Code logs",
            detail: "Debug logs and shell snapshots. Transcripts are left untouched.",
            relativePaths: [".claude/debug", ".claude/shell-snapshots"], defaultOn: true),
        Entry(
            id: "claudeMcp", name: "Claude Code MCP logs",
            detail: "MCP server logs that can grow very large.",
            relativePaths: ["Library/Caches/claude-cli-nodejs"], defaultOn: true),
    ]

    public static func resolve(_ entry: Entry, home: URL) -> [URL] {
        entry.relativePaths
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public enum JunkScanner {
    public static func directorySize(_ url: URL, isCancelled: () -> Bool = { false }) -> Int64 {
        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey,
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [])
        else {
            let single = try? url.resourceValues(forKeys: Set(keys))
            return Int64(single?.totalFileAllocatedSize ?? single?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        var seen = 0
        for case let item as URL in enumerator {
            seen += 1
            if seen & 0x3ff == 0, isCancelled() { break }
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    public static func scanCategory(
        _ entry: JunkCatalog.Entry, home: URL, isCancelled: () -> Bool = { false }
    ) -> JunkCategory? {
        let paths = JunkCatalog.resolve(entry, home: home)
        guard !paths.isEmpty else { return nil }
        var items: [JunkItem] = []
        for path in paths {
            let children =
                (try? FileManager.default.contentsOfDirectory(
                    at: path, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? []
            if children.isEmpty {
                let size = directorySize(path, isCancelled: isCancelled)
                if size > 0 {
                    items.append(
                        JunkItem(
                            id: path.path, name: path.lastPathComponent, path: path,
                            sizeBytes: size, selected: entry.defaultOn))
                }
            } else {
                for child in children {
                    if isCancelled() { break }
                    let size = directorySize(child, isCancelled: isCancelled)
                    guard size > 0 else { continue }
                    items.append(
                        JunkItem(
                            id: child.path, name: child.lastPathComponent, path: child,
                            sizeBytes: size, selected: entry.defaultOn))
                }
            }
        }
        guard !items.isEmpty else { return nil }
        items.sort { $0.sizeBytes > $1.sizeBytes }
        return JunkCategory(id: entry.id, name: entry.name, detail: entry.detail, items: items)
    }

    public static func drives() -> [DriveInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeIsRemovableKey,
            .volumeIsInternalKey,
        ]
        guard
            let volumes = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
        else { return [] }
        return volumes.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isSystemVolume = url.path == "/"
            return DriveInfo(
                id: url.path,
                name: values?.volumeName ?? (isSystemVolume ? "/" : url.lastPathComponent),
                totalBytes: Int64(values?.volumeTotalCapacity ?? 0),
                isRemovable: values?.volumeIsRemovable ?? !isSystemVolume,
                isInternal: values?.volumeIsInternal ?? isSystemVolume)
        }
        .sorted { $0.isExternal == $1.isExternal ? $0.totalBytes > $1.totalBytes : !$0.isExternal }
    }

    public static func drivesForScanning(
        _ drives: [DriveInfo], selectedDriveIDs: Set<String>?
    ) -> [DriveInfo] {
        let selection = selectedDriveIDs ?? ["/"]
        return drives.filter { selection.contains($0.id) }
    }

    public static func clean(_ items: [JunkItem]) -> Int64 {
        var reclaimed: Int64 = 0
        for item in items {
            if (try? FileManager.default.trashItem(at: item.path, resultingItemURL: nil)) != nil {
                reclaimed += item.sizeBytes
            }
        }
        return reclaimed
    }

    public static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    public struct ProjectTarget: Sendable {
        public let dir: String
        public let categoryID: String
        public let categoryName: String
        public let detail: String

        public init(dir: String, categoryID: String, categoryName: String, detail: String) {
            self.dir = dir
            self.categoryID = categoryID
            self.categoryName = categoryName
            self.detail = detail
        }
    }

    public static let projectTargets: [ProjectTarget] = [
        ProjectTarget(
            dir: "node_modules", categoryID: "nodeModules", categoryName: "node_modules",
            detail: "JavaScript dependencies, restored by install."),
        ProjectTarget(
            dir: "__pycache__", categoryID: "pycache", categoryName: "Python __pycache__",
            detail: "Compiled bytecode caches."),
        ProjectTarget(
            dir: ".venv", categoryID: "pyvenv", categoryName: "Python virtualenvs",
            detail: "Recreated from requirements."),
        ProjectTarget(
            dir: "venv", categoryID: "pyvenv", categoryName: "Python virtualenvs",
            detail: "Recreated from requirements."),
        ProjectTarget(
            dir: "target", categoryID: "rustTarget", categoryName: "Cargo / Maven target",
            detail: "Build output, rebuilt on next build."),
        ProjectTarget(
            dir: ".gradle", categoryID: "gradle", categoryName: "Gradle caches",
            detail: "Rebuilt on next build."),
        ProjectTarget(
            dir: "Pods", categoryID: "pods", categoryName: "CocoaPods",
            detail: "Restored by pod install."),
        ProjectTarget(
            dir: ".next", categoryID: "nextBuild", categoryName: "Next.js .next",
            detail: "Rebuilt on next build."),
        ProjectTarget(
            dir: ".turbo", categoryID: "turbo", categoryName: "Turborepo cache",
            detail: "Rebuilt on next build."),
    ]

    private static let walkSkip: Set<String> = [
        "System", "Library", "Applications", "usr", "bin", "sbin", "opt", "private", "cores",
        "dev", "Volumes", "Network", "Photos Library.photoslibrary",
    ]

    public static func scanProjectJunk(
        roots: [URL], isCancelled: @escaping () -> Bool = { false },
        progress: @escaping (String) -> Void
    ) -> [JunkCategory] {
        let targets = Dictionary(
            projectTargets.map { ($0.dir, $0) }, uniquingKeysWith: { first, _ in first })
        var itemsByCategory: [String: [JunkItem]] = [:]
        var count = 0
        let budget = 600
        let maxDepth = 9
        let fm = FileManager.default

        func walk(_ dir: URL, depth: Int) {
            guard depth <= maxDepth, count < budget, !isCancelled() else { return }
            guard
                let children = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [])
            else { return }
            for child in children {
                guard count < budget, !isCancelled() else { return }
                let values = try? child.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey,
                ])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                let name = child.lastPathComponent
                if let target = targets[name] {
                    let size = directorySize(child, isCancelled: isCancelled)
                    if size > 0 {
                        itemsByCategory[target.categoryID, default: []].append(
                            JunkItem(
                                id: child.path, name: projectLabel(child), path: child,
                                sizeBytes: size, selected: false))
                        count += 1
                    }
                    continue
                }
                if walkSkip.contains(name) || name.hasPrefix(".") { continue }
                walk(child, depth: depth + 1)
            }
        }

        for root in roots {
            if isCancelled() { break }
            progress(
                "Scanning \(root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent) for project junk…"
            )
            walk(root, depth: 0)
        }

        return projectTargets.reduce(into: [String: JunkCategory]()) { result, target in
            guard result[target.categoryID] == nil, let items = itemsByCategory[target.categoryID]
            else { return }
            let sorted = items.sorted { $0.sizeBytes > $1.sizeBytes }
            result[target.categoryID] = JunkCategory(
                id: target.categoryID, name: target.categoryName, detail: target.detail,
                items: sorted)
        }
        .values
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private static func projectLabel(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
