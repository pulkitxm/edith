import Foundation

struct JunkItem: Identifiable, Sendable {
    let id: String
    let name: String
    let path: URL
    var sizeBytes: Int64
    var selected: Bool
}

enum JunkSelection {
    case all, none, some
}

struct JunkCategory: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String
    var items: [JunkItem]

    var sizeBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    var selectedBytes: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.sizeBytes } }

    var selection: JunkSelection {
        let selected = items.filter(\.selected).count
        if selected == 0 { return .none }
        if selected == items.count { return .all }
        return .some
    }
}

struct DriveInfo: Identifiable, Sendable {
    let id: String
    let name: String
    let totalBytes: Int64
    let usedBytes: Int64
    let isExternal: Bool

    var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}

enum JunkCatalog {
    struct Entry {
        let id: String
        let name: String
        let detail: String
        let relativePaths: [String]
        let defaultOn: Bool
    }

    static let entries: [Entry] = [
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

    static func resolve(_ entry: Entry, home: URL) -> [URL] {
        entry.relativePaths
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

enum JunkScanner {
    static func directorySize(_ url: URL) -> Int64 {
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
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func scanCategory(_ entry: JunkCatalog.Entry, home: URL) -> JunkCategory? {
        let paths = JunkCatalog.resolve(entry, home: home)
        guard !paths.isEmpty else { return nil }
        var items: [JunkItem] = []
        for path in paths {
            let children =
                (try? FileManager.default.contentsOfDirectory(
                    at: path, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? []
            if children.isEmpty {
                let size = directorySize(path)
                if size > 0 {
                    items.append(
                        JunkItem(
                            id: path.path, name: path.lastPathComponent, path: path,
                            sizeBytes: size, selected: entry.defaultOn))
                }
            } else {
                for child in children {
                    let size = directorySize(child)
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

    static func drives() -> [DriveInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsInternalKey, .volumeIsBrowsableKey,
        ]
        guard
            let volumes = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
        else { return [] }
        return volumes.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.volumeIsBrowsable == true,
                let total = values.volumeTotalCapacity, total > 0
            else { return nil }
            let available = values.volumeAvailableCapacity ?? 0
            return DriveInfo(
                id: url.path, name: values.volumeName ?? url.lastPathComponent,
                totalBytes: Int64(total), usedBytes: Int64(total - available),
                isExternal: !(values.volumeIsInternal ?? true))
        }
        .sorted { $0.isExternal == $1.isExternal ? $0.totalBytes > $1.totalBytes : !$0.isExternal }
    }

    static func clean(_ items: [JunkItem]) -> Int64 {
        var reclaimed: Int64 = 0
        for item in items {
            let size = directorySize(item.path)
            if (try? FileManager.default.trashItem(at: item.path, resultingItemURL: nil)) != nil {
                reclaimed += size
            }
        }
        return reclaimed
    }

    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    struct ProjectTarget {
        let dir: String
        let categoryID: String
        let categoryName: String
        let detail: String
    }

    static let projectTargets: [ProjectTarget] = [
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

    static func scanProjectJunk(
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
                    let size = directorySize(child)
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
