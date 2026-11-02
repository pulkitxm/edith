import Foundation
import EdithExtensionSupport

public struct JunkItem: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let path: URL
    public var sizeBytes: Int64
    public var selected: Bool
    public var lastModified: Date?
    public var worktree: WorktreeInfo?

    public init(
        id: String, name: String, path: URL, sizeBytes: Int64, selected: Bool,
        lastModified: Date? = nil, worktree: WorktreeInfo? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.sizeBytes = sizeBytes
        self.selected = selected
        self.lastModified = lastModified
        self.worktree = worktree
    }
}

public enum JunkSelection: Sendable {
    case all, none, some
}

public struct JunkCategory: Codable, Identifiable, Sendable {
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

public struct DriveInfo: Codable, Identifiable, Sendable {
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
            relativePaths: ["Library/Developer/Xcode/DerivedData"],
            defaultOn: true),
        Entry(
            id: "xcodeDeviceSupport", name: "Xcode device support",
            detail: "Debug symbols copied from devices, recreated when a device connects.",
            relativePaths: [
                "Library/Developer/Xcode/iOS DeviceSupport",
                "Library/Developer/Xcode/watchOS DeviceSupport",
                "Library/Developer/Xcode/tvOS DeviceSupport",
                "Library/Developer/Xcode/visionOS DeviceSupport",
            ],
            defaultOn: true),
        Entry(
            id: "xcodePreviews", name: "Xcode previews",
            detail: "SwiftUI preview builds, rebuilt on demand.",
            relativePaths: ["Library/Developer/Xcode/UserData/Previews"],
            defaultOn: true),
        Entry(
            id: "simulatorCaches", name: "Simulator caches",
            detail: "CoreSimulator caches. Simulator devices and their data stay.",
            relativePaths: ["Library/Developer/CoreSimulator/Caches"],
            defaultOn: true),
        Entry(
            id: "xcodeArchives", name: "Xcode archives",
            detail: "Archived release builds and dSYMs. Keep the ones you still ship.",
            relativePaths: ["Library/Developer/Xcode/Archives"],
            defaultOn: false),
        Entry(
            id: "swiftpm", name: "Swift Package cache",
            detail: "Cached package checkouts, re-fetched on demand.",
            relativePaths: ["Library/Caches/org.swift.swiftpm"],
            defaultOn: true),
        Entry(
            id: "cocoapods", name: "CocoaPods cache",
            detail: "Downloaded pods, re-fetched by pod install.",
            relativePaths: ["Library/Caches/CocoaPods"],
            defaultOn: true),
        Entry(
            id: "carthage", name: "Carthage cache",
            detail: "Downloaded frameworks, re-fetched on bootstrap.",
            relativePaths: ["Library/Caches/org.carthage.CarthageKit"],
            defaultOn: true),
        Entry(
            id: "npm", name: "npm cache",
            detail: "Tarball cache, re-downloaded on install.",
            relativePaths: [".npm/_cacache"],
            defaultOn: true),
        Entry(
            id: "yarn", name: "Yarn cache",
            detail: "Re-downloaded on install.",
            relativePaths: ["Library/Caches/Yarn", ".yarn/berry/cache"],
            defaultOn: true),
        Entry(
            id: "pnpm", name: "pnpm store",
            detail: "Content-addressed store, re-downloaded on install.",
            relativePaths: ["Library/pnpm/store", ".pnpm-store", ".local/share/pnpm/store"],
            defaultOn: true),
        Entry(
            id: "bun", name: "Bun cache",
            detail: "Re-downloaded on install.",
            relativePaths: [".bun/install/cache"],
            defaultOn: true),
        Entry(
            id: "deno", name: "Deno cache",
            detail: "Remote modules and compiled code, re-downloaded on run.",
            relativePaths: ["Library/Caches/deno"],
            defaultOn: true),
        Entry(
            id: "nodeGyp", name: "node-gyp and Electron headers",
            detail: "Native addon headers, re-downloaded on rebuild.",
            relativePaths: ["Library/Caches/node-gyp", ".electron-gyp"],
            defaultOn: true),
        Entry(
            id: "electron", name: "Electron downloads",
            detail: "Electron and electron-builder binaries, re-downloaded on build.",
            relativePaths: ["Library/Caches/electron", "Library/Caches/electron-builder"],
            defaultOn: true),
        Entry(
            id: "turbo", name: "Turborepo cache",
            detail: "Local task cache, rebuilt on next run.",
            relativePaths: ["Library/Caches/turborepo"],
            defaultOn: true),
        Entry(
            id: "typescript", name: "TypeScript cache",
            detail: "Editor type acquisition cache.",
            relativePaths: ["Library/Caches/typescript"],
            defaultOn: true),
        Entry(
            id: "prisma", name: "Prisma engines",
            detail: "Query engine binaries, re-downloaded on generate.",
            relativePaths: [".cache/prisma"],
            defaultOn: true),
        Entry(
            id: "pip", name: "pip cache",
            detail: "Wheel cache, re-downloaded on install.",
            relativePaths: ["Library/Caches/pip"],
            defaultOn: true),
        Entry(
            id: "uv", name: "uv cache",
            detail: "Wheel and source cache, re-downloaded on sync.",
            relativePaths: [".cache/uv", "Library/Caches/uv"],
            defaultOn: true),
        Entry(
            id: "poetry", name: "Poetry cache",
            detail: "Package cache, re-downloaded on install.",
            relativePaths: ["Library/Caches/pypoetry"],
            defaultOn: true),
        Entry(
            id: "conda", name: "Conda package cache",
            detail: "Downloaded packages. Environments stay.",
            relativePaths: ["miniconda3/pkgs", "anaconda3/pkgs", "miniforge3/pkgs", ".conda/pkgs"],
            defaultOn: false),
        Entry(
            id: "huggingFace", name: "Hugging Face models",
            detail: "Downloaded models and datasets. Large to fetch again.",
            relativePaths: [".cache/huggingface/hub"],
            defaultOn: false),
        Entry(
            id: "cargo", name: "Cargo registry",
            detail: "Downloaded crates and git checkouts, re-fetched on build.",
            relativePaths: [
                ".cargo/registry/cache", ".cargo/registry/src", ".cargo/git/checkouts",
                ".cargo/git/db",
            ],
            defaultOn: false),
        Entry(
            id: "goBuild", name: "Go build cache",
            detail: "Compiled packages, rebuilt on next build.",
            relativePaths: ["Library/Caches/go-build"],
            defaultOn: true),
        Entry(
            id: "goModules", name: "Go module cache",
            detail: "Downloaded modules, re-fetched on build.",
            relativePaths: ["go/pkg/mod"],
            defaultOn: false),
        Entry(
            id: "golangciLint", name: "golangci-lint cache",
            detail: "Lint results, rebuilt on next run.",
            relativePaths: ["Library/Caches/golangci-lint"],
            defaultOn: true),
        Entry(
            id: "gradle", name: "Gradle caches",
            detail: "Dependencies, wrappers and daemon logs, re-downloaded on build.",
            relativePaths: [".gradle/caches", ".gradle/wrapper/dists", ".gradle/daemon"],
            defaultOn: false),
        Entry(
            id: "maven", name: "Maven repository",
            detail: "Downloaded artifacts, re-fetched on build.",
            relativePaths: [".m2/repository"],
            defaultOn: false),
        Entry(
            id: "sbt", name: "sbt and Coursier caches",
            detail: "Scala dependencies, re-fetched on build.",
            relativePaths: ["Library/Caches/Coursier", ".ivy2/cache", ".sbt/boot"],
            defaultOn: false),
        Entry(
            id: "android", name: "Android build cache",
            detail: "Gradle and SDK caches. Emulators stay.",
            relativePaths: [".android/cache", ".android/build-cache"],
            defaultOn: true),
        Entry(
            id: "androidImages", name: "Android system images",
            detail: "Emulator images, re-downloaded from the SDK manager.",
            relativePaths: ["Library/Android/sdk/system-images"],
            defaultOn: false),
        Entry(
            id: "pub", name: "Dart pub cache",
            detail: "Downloaded packages, re-fetched by pub get.",
            relativePaths: [".pub-cache/hosted", ".pub-cache/git"],
            defaultOn: false),
        Entry(
            id: "dartServer", name: "Dart analysis cache",
            detail: "Analyzer state, rebuilt by the editor.",
            relativePaths: [".dartServer"],
            defaultOn: true),
        Entry(
            id: "composer", name: "Composer cache",
            detail: "PHP packages, re-downloaded on install.",
            relativePaths: ["Library/Caches/composer", ".composer/cache"],
            defaultOn: true),
        Entry(
            id: "bundler", name: "Bundler cache",
            detail: "Ruby gem downloads, re-fetched by bundle install.",
            relativePaths: [".bundle/cache"],
            defaultOn: true),
        Entry(
            id: "hex", name: "Hex packages",
            detail: "Elixir package downloads, re-fetched by mix deps.get.",
            relativePaths: [".hex/packages"],
            defaultOn: true),
        Entry(
            id: "cabal", name: "Cabal packages",
            detail: "Haskell package downloads, re-fetched on build.",
            relativePaths: [".cabal/packages"],
            defaultOn: true),
        Entry(
            id: "nuget", name: "NuGet packages",
            detail: "Downloaded .NET packages, restored by dotnet restore.",
            relativePaths: [".nuget/packages"],
            defaultOn: false),
        Entry(
            id: "zigCache", name: "Zig cache",
            detail: "Global build cache, rebuilt on next build.",
            relativePaths: [".cache/zig", "Library/Caches/zig"],
            defaultOn: true),
        Entry(
            id: "compilerCache", name: "ccache and sccache",
            detail: "Compiler output caches, rebuilt on next build.",
            relativePaths: ["Library/Caches/ccache", ".ccache", "Library/Caches/Mozilla.sccache"],
            defaultOn: true),
        Entry(
            id: "bazelisk", name: "Bazelisk downloads",
            detail: "Bazel binaries, re-downloaded on run.",
            relativePaths: ["Library/Caches/bazelisk"],
            defaultOn: true),
        Entry(
            id: "homebrew", name: "Homebrew cache",
            detail: "Downloaded bottles.",
            relativePaths: ["Library/Caches/Homebrew"],
            defaultOn: true),
        Entry(
            id: "playwright", name: "Playwright browsers",
            detail: "Re-downloaded on next test run.",
            relativePaths: ["Library/Caches/ms-playwright"],
            defaultOn: false),
        Entry(
            id: "puppeteer", name: "Puppeteer cache",
            detail: "Re-downloaded on next run.",
            relativePaths: [".cache/puppeteer"],
            defaultOn: false),
        Entry(
            id: "cypress", name: "Cypress binaries",
            detail: "Re-downloaded on next install.",
            relativePaths: ["Library/Caches/Cypress"],
            defaultOn: false),
        Entry(
            id: "jetbrains", name: "JetBrains caches",
            detail: "IDE indexes and logs. Settings stay.",
            relativePaths: ["Library/Caches/JetBrains", "Library/Logs/JetBrains"],
            defaultOn: true),
        Entry(
            id: "vscode", name: "VS Code caches",
            detail: "Cached data, extension downloads and logs. Settings stay.",
            relativePaths: [
                "Library/Application Support/Code/Cache",
                "Library/Application Support/Code/CachedData",
                "Library/Application Support/Code/CachedExtensionVSIXs",
                "Library/Application Support/Code/logs",
            ],
            defaultOn: true),
        Entry(
            id: "cursor", name: "Cursor caches",
            detail: "Cached data, extension downloads and logs. Settings stay.",
            relativePaths: [
                "Library/Application Support/Cursor/Cache",
                "Library/Application Support/Cursor/CachedData",
                "Library/Application Support/Cursor/CachedExtensionVSIXs",
                "Library/Application Support/Cursor/logs",
            ],
            defaultOn: true),
        Entry(
            id: "zed", name: "Zed caches",
            detail: "Editor caches. Settings stay.",
            relativePaths: ["Library/Caches/Zed"],
            defaultOn: true),
        Entry(
            id: "claudeCode", name: "Claude Code logs",
            detail: "Debug logs and shell snapshots. Transcripts are left untouched.",
            relativePaths: [".claude/debug", ".claude/shell-snapshots"],
            defaultOn: true),
        Entry(
            id: "claudeMcp", name: "Claude Code MCP logs",
            detail: "MCP server logs that can grow very large.",
            relativePaths: ["Library/Caches/claude-cli-nodejs"],
            defaultOn: true),
        Entry(
            id: "codexLogs", name: "Codex logs",
            detail: "Codex CLI logs. Sessions are left untouched.",
            relativePaths: [".codex/log"],
            defaultOn: true),
    ]

    public static func resolve(_ entry: Entry, home: URL) -> [URL] {
        entry.relativePaths
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public enum JunkScanner {
    public static func directorySize(_ url: URL, isCancelled: () -> Bool = { false }) -> Int64 {
        measure(url, isCancelled: isCancelled).bytes
    }

    static func measure(
        _ url: URL, isCancelled: () -> Bool = { false }
    ) -> (bytes: Int64, latest: Date?) {
        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey,
            .contentModificationDateKey,
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [])
        else {
            let single = try? url.resourceValues(forKeys: Set(keys))
            return (
                Int64(single?.totalFileAllocatedSize ?? single?.fileAllocatedSize ?? 0),
                single?.contentModificationDate
            )
        }
        var total: Int64 = 0
        var latest: Date?
        var seen = 0
        for case let item as URL in enumerator {
            seen += 1
            if seen & 0x3ff == 0, isCancelled() { break }
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            latest = later(latest, values.contentModificationDate)
        }
        return (total, latest)
    }

    static func later(_ first: Date?, _ second: Date?) -> Date? {
        guard let first else { return second }
        guard let second else { return first }
        return max(first, second)
    }

    public static func outermost(_ items: [JunkItem]) -> [JunkItem] {
        let paths = Set(items.map { $0.path.standardizedFileURL.path })
        return items.filter { item in
            var current = item.path.standardizedFileURL.deletingLastPathComponent()
            while current.path != "/" && !current.path.isEmpty {
                if paths.contains(current.path) { return false }
                current = current.deletingLastPathComponent()
            }
            return true
        }
    }

    public static func uniqueBytes(_ items: [JunkItem]) -> Int64 {
        outermost(items).reduce(0) { $0 + $1.sizeBytes }
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

    public static func scanCategories(
        _ entries: [JunkCatalog.Entry], home: URL,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> [JunkCategory] {
        await BlockingWork.value {
            entries.compactMap { scanCategory($0, home: home, isCancelled: isCancelled) }
        }
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

    public static func clean(_ items: [JunkItem], isCancelled: () -> Bool = { false }) -> Int64 {
        var reclaimed: Int64 = 0
        var repositories: Set<String> = []
        for item in outermost(items) {
            guard !isCancelled() else { break }
            if (try? FileManager.default.trashItem(at: item.path, resultingItemURL: nil)) != nil {
                reclaimed += item.sizeBytes
                if let repository = item.worktree?.repository { repositories.insert(repository) }
            }
        }
        Worktrees.prune(repositories: repositories)
        return reclaimed
    }

    public static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static let walkSkip: Set<String> = [
        "System", "Library", "Applications", "usr", "bin", "sbin", "opt", "private", "cores",
        "dev", "Volumes", "Network",
    ]

    private static let walkSkipSuffixes = [
        ".app", ".photoslibrary", ".xcodeproj", ".xcworkspace", ".xcassets", ".framework",
        ".xcframework", ".bundle", ".lproj",
    ]

    public static let maxProjectItems = 5000
    static let maxWalkDepth = 12

    private final class WorktreeTally {
        let path: URL
        let link: Worktrees.Link
        var bytes: Int64 = 0
        var latest: Date?

        init(path: URL, link: Worktrees.Link) {
            self.path = path
            self.link = link
            latest = Worktrees.gitActivity(link)
        }

        func add(_ bytes: Int64, latest date: Date?) {
            self.bytes += bytes
            latest = JunkScanner.later(latest, date)
        }
    }

    public static func scanProjectJunk(
        roots: [URL], isCancelled: @escaping () -> Bool = { false },
        progress: @escaping (String) -> Void
    ) -> [JunkCategory] {
        var itemsByCategory: [String: [JunkItem]] = [:]
        var tallies: [WorktreeTally] = []
        var count = 0
        let fm = FileManager.default
        let ignore = GitIgnoreLookup()
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey, .contentModificationDateKey,
        ]

        func walk(_ dir: URL, depth: Int, enclosing: [WorktreeTally]) {
            guard !isCancelled() else { return }
            guard
                let children = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: keys, options: [])
            else { return }
            let names = children.map(\.lastPathComponent)
            var enclosing = enclosing
            if names.contains(".git"), let link = Worktrees.link(at: dir) {
                let tally = WorktreeTally(path: dir, link: link)
                tallies.append(tally)
                enclosing.append(tally)
            }
            var activity: Date?
            var found: [(URL, ProjectRule, Int64)] = []
            for child in children {
                guard !isCancelled() else { return }
                let values = try? child.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true { continue }
                let modified = values?.contentModificationDate
                guard values?.isDirectory == true else {
                    activity = later(activity, modified)
                    let size = Int64(
                        values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
                    for tally in enclosing { tally.add(size, latest: modified) }
                    continue
                }
                let name = child.lastPathComponent
                if let rule = ProjectRules.match(
                    name: name, directory: dir, siblings: names, ignore: ignore)
                {
                    let size = directorySize(child, isCancelled: isCancelled)
                    for tally in enclosing { tally.add(size, latest: nil) }
                    if size > 0, count < maxProjectItems {
                        found.append((child, rule, size))
                        count += 1
                    }
                    continue
                }
                activity = later(activity, modified)
                let container = worktreeContainer(child, name: name)
                if let container { walk(container, depth: depth + 2, enclosing: []) }
                if container == nil, name == ".worktrees" {
                    walk(child, depth: depth + 1, enclosing: enclosing)
                    continue
                }
                if skipsWalk(name) || depth >= maxWalkDepth || count >= maxProjectItems {
                    if !enclosing.isEmpty {
                        let measured = measure(child, isCancelled: isCancelled)
                        for tally in enclosing {
                            tally.add(measured.bytes, latest: measured.latest)
                        }
                    }
                    continue
                }
                walk(child, depth: depth + 1, enclosing: enclosing)
            }
            for (child, rule, size) in found {
                itemsByCategory[rule.categoryID, default: []].append(
                    JunkItem(
                        id: child.path, name: projectLabel(child), path: child, sizeBytes: size,
                        selected: false, lastModified: activity))
            }
        }

        for root in roots {
            if isCancelled() { break }
            progress(
                "Scanning \(root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent) for project junk…"
            )
            walk(root, depth: 0, enclosing: [])
        }

        var categories = ProjectRules.categories.compactMap { category -> JunkCategory? in
            guard let items = itemsByCategory[category.id] else { return nil }
            return JunkCategory(
                id: category.id, name: category.name, detail: category.detail,
                items: items.map { item in
                    var copy = item
                    copy.lastModified = later(
                        item.lastModified, enclosingActivity(item.path, tallies: tallies))
                    return copy
                })
        }
        if !tallies.isEmpty, !isCancelled() {
            progress("Checking \(tallies.count) git worktrees…")
            var seen: Set<String> = []
            let items = tallies.compactMap { tally -> JunkItem? in
                guard seen.insert(tally.path.standardizedFileURL.path).inserted else { return nil }
                return JunkItem(
                    id: tally.path.path, name: projectLabel(tally.path), path: tally.path,
                    sizeBytes: tally.bytes, selected: false, lastModified: tally.latest,
                    worktree: Worktrees.info(tally.link))
            }
            categories.append(
                JunkCategory(
                    id: Worktrees.categoryID, name: "Git worktrees",
                    detail: "Removes the worktree folder only. Its branch and commits stay.",
                    items: Worktrees.inspect(items, isCancelled: isCancelled)))
        }
        return categories.map { category in
            var sorted = category
            sorted.items.sort { $0.sizeBytes > $1.sizeBytes }
            return sorted
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private static func enclosingActivity(_ path: URL, tallies: [WorktreeTally]) -> Date? {
        let itemPath = path.standardizedFileURL.path
        return tallies.filter { itemPath.hasPrefix($0.path.standardizedFileURL.path + "/") }
            .compactMap(\.latest).max()
    }

    private static func worktreeContainer(_ directory: URL, name: String) -> URL? {
        guard Worktrees.containers.contains(name) else { return nil }
        let container = directory.appendingPathComponent("worktrees")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: container.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return container
    }

    static func skipsWalk(_ name: String) -> Bool {
        name.hasPrefix(".") || walkSkip.contains(name)
            || walkSkipSuffixes.contains { name.hasSuffix($0) }
    }

    private static func projectLabel(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
