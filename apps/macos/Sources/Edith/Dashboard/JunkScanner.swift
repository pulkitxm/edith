import Foundation

struct JunkCategory: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String
    let paths: [URL]
    var sizeBytes: Int64
    var selected: Bool
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
            detail: "Debug logs and shell snapshots. Your transcripts are left untouched.",
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
        else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [JunkCategory]
    {
        JunkCatalog.entries.compactMap { entry in
            let paths = JunkCatalog.resolve(entry, home: home)
            guard !paths.isEmpty else { return nil }
            let size = paths.reduce(Int64(0)) { $0 + directorySize($1) }
            guard size > 0 else { return nil }
            return JunkCategory(
                id: entry.id, name: entry.name, detail: entry.detail, paths: paths,
                sizeBytes: size, selected: entry.defaultOn)
        }
    }

    static func clean(_ categories: [JunkCategory]) -> Int64 {
        var reclaimed: Int64 = 0
        for category in categories {
            for path in category.paths {
                let size = directorySize(path)
                if (try? FileManager.default.trashItem(at: path, resultingItemURL: nil)) != nil {
                    reclaimed += size
                }
            }
        }
        return reclaimed
    }

    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
