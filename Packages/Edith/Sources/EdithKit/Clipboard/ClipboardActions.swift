import AppKit
import Foundation

public enum ClipboardActionError: Error, Equatable {
    case blobMissing
}

public enum ClipboardActions {
    public struct Outcome: Sendable {
        public let entries: [ClipboardEntry]
        public let changed: Int

        public init(entries: [ClipboardEntry], changed: Int) {
            self.entries = entries
            self.changed = changed
        }
    }

    public struct KindTotal: Sendable, Equatable {
        public let kind: ClipboardEntry.Kind
        public let count: Int
        public let bytes: Int
    }

    public struct Stats: Sendable, Equatable {
        public let count: Int
        public let pinned: Int
        public let bytes: Int
        public let diskBytes: Int
        public let largest: Int
        public let oldest: Date?
        public let newest: Date?
        public let byKind: [KindTotal]
    }

    public static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func matches(_ entry: ClipboardEntry, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if entry.preview?.lowercased().contains(query) == true { return true }
        if entry.sourceApp?.lowercased().contains(query) == true { return true }
        return false
    }

    public static func arrange(
        _ entries: [ClipboardEntry], query: String = "", pinToTop: Bool = true
    ) -> [ClipboardEntry] {
        let needle = normalized(query)
        let matched = entries.filter { matches($0, query: needle) }
        let pinned = matched.filter(\.pinned).sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        let loose = matched.filter { !$0.pinned }.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        return pinToTop ? pinned + loose : loose + pinned
    }

    public static func pinToTopPreference(_ defaults: UserDefaults = SharedDefaults.store) -> Bool {
        (defaults.string(forKey: "clipboardPinTo") ?? "top") != "bottom"
    }

    public static func listed(
        query: String = "", defaults: UserDefaults = SharedDefaults.store
    ) -> [ClipboardEntry] {
        arrange(
            ClipboardRepository.loadEntries(), query: query,
            pinToTop: pinToTopPreference(defaults))
    }

    @discardableResult
    public static func setPinned(_ pinned: Bool, ids: Set<String>) throws -> Outcome {
        try mutate { entries in
            var changed = 0
            for index in entries.indices where ids.contains(entries[index].id) {
                guard entries[index].pinned != pinned else { continue }
                entries[index].pinned = pinned
                changed += 1
            }
            return changed
        }
    }

    @discardableResult
    public static func togglePin(ids: Set<String>) throws -> Outcome {
        try mutate { entries in
            var changed = 0
            for index in entries.indices where ids.contains(entries[index].id) {
                entries[index].pinned.toggle()
                changed += 1
            }
            return changed
        }
    }

    @discardableResult
    public static func delete(ids: Set<String>) throws -> Outcome {
        try mutate(pruningBlobs: true) { entries in
            let before = entries.count
            entries.removeAll { ids.contains($0.id) }
            return before - entries.count
        }
    }

    @discardableResult
    public static func clear(keepingPinned: Bool) throws -> Outcome {
        try mutate(pruningBlobs: true) { entries in
            let before = entries.count
            entries = keepingPinned ? entries.filter(\.pinned) : []
            return before - entries.count
        }
    }

    @discardableResult
    public static func markCopied(id: String, at moment: Date = Date()) throws -> Outcome {
        try mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return 0 }
            entries[index].lastCopiedAt = moment
            return 1
        }
    }

    @discardableResult
    public static func copy(
        _ entry: ClipboardEntry, asPlainText: Bool, pasteboard: NSPasteboard = .general
    ) throws -> Outcome {
        guard
            ClipboardRepository.copyToPasteboard(
                entry, asPlainText: asPlainText, pasteboard: pasteboard)
        else { throw ClipboardActionError.blobMissing }
        return try markCopied(id: entry.id)
    }

    public static func stats(_ entries: [ClipboardEntry]? = nil) -> Stats {
        let all = entries ?? ClipboardRepository.loadEntries()
        var counts: [ClipboardEntry.Kind: (count: Int, bytes: Int)] = [:]
        for entry in all {
            let running = counts[entry.kind] ?? (0, 0)
            counts[entry.kind] = (running.count + 1, running.bytes + entry.size)
        }
        let byKind = ClipboardEntry.Kind.allCases.compactMap { kind -> KindTotal? in
            guard let total = counts[kind] else { return nil }
            return KindTotal(kind: kind, count: total.count, bytes: total.bytes)
        }
        return Stats(
            count: all.count,
            pinned: all.filter(\.pinned).count,
            bytes: all.reduce(0) { $0 + $1.size },
            diskBytes: ClipboardRepository.blobBytesOnDisk(),
            largest: all.map(\.size).max() ?? 0,
            oldest: all.map(\.createdAt).min(),
            newest: all.map(\.lastCopiedAt).max(),
            byKind: byKind)
    }

    private static func mutate(
        pruningBlobs: Bool = false, _ body: (inout [ClipboardEntry]) -> Int
    ) throws -> Outcome {
        try ClipboardRepository.withIndexLock {
            var entries = ClipboardRepository.loadEntries()
            let changed = body(&entries)
            guard changed > 0 else { return Outcome(entries: entries, changed: 0) }
            try ClipboardRepository.saveEntries(entries)
            if pruningBlobs { ClipboardRepository.pruneOrphanBlobs(keeping: entries) }
            return Outcome(entries: entries, changed: changed)
        }
    }
}
