import Darwin
import Foundation

public struct AttentionRepository: Sendable {
    nonisolated(unsafe) public static var sink: AttentionEventSink?

    public let root: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL = AttentionPaths.root) {
        self.root = root
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public var directory: URL { root.appendingPathComponent("attention") }
    public var eventsDirectory: URL { directory.appendingPathComponent("events") }
    public var settingsFile: URL { directory.appendingPathComponent("settings.json") }
    public var activeFocusFile: URL { directory.appendingPathComponent("active-focus.json") }
    public var focusHistoryFile: URL { directory.appendingPathComponent("focus.jsonl") }
    public var browserHistoryFile: URL { directory.appendingPathComponent("browser-history.json") }
    public var lockFile: URL { directory.appendingPathComponent(".lock") }

    public func eventFile(for date: Date) -> URL {
        let parts = AttentionPaths.utcCalendar.dateComponents([.year, .month, .day], from: date)
        let name = String(
            format: "%04d-%02d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return eventsDirectory.appendingPathComponent(name)
    }

    public func loadSettings() -> AttentionSettings {
        withLock {
            guard let data = try? Data(contentsOf: settingsFile),
                let settings = try? decoder.decode(AttentionSettings.self, from: data)
            else { return AttentionSettings() }
            return settings
        }
    }

    public func saveSettings(_ settings: AttentionSettings) throws {
        try withLock {
            try prepare()
            try encoder.encode(settings).write(to: settingsFile, options: .atomic)
        }
    }

    public func append(_ event: AttentionEvent, pulseTime: TimeInterval = 30) throws {
        guard event.duration > 0 else { return }
        if let sink = Self.sink {
            do {
                try sink.record(AttentionBatch(events: [event], pulseTime: pulseTime))
                return
            } catch {
                try appendToFile(event, pulseTime: pulseTime)
                return
            }
        }
        try appendToFile(event, pulseTime: pulseTime)
    }

    private func appendToFile(_ event: AttentionEvent, pulseTime: TimeInterval) throws {
        try withLock {
            try prepare()
            let file = eventFile(for: event.startedAt)
            var events = decodeEvents((try? Data(contentsOf: file)) ?? Data())
            if let last = events.last, last.canMerge(with: event, pulseTime: pulseTime) {
                events[events.count - 1] = last.merged(with: event)
                try encodeLines(events).write(to: file, options: .atomic)
                return
            }
            let line = try encoder.encode(event) + Data([0x0A])
            if !FileManager.default.fileExists(atPath: file.path) {
                try line.write(to: file, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
    }

    public func events(from: Date, to: Date) -> [AttentionEvent] {
        guard to > from else { return [] }
        if let sink = Self.sink, let events = try? sink.events(from: from, to: to) {
            return events
        }
        return eventsFromFiles(from: from, to: to)
    }

    private func eventsFromFiles(from: Date, to: Date) -> [AttentionEvent] {
        withLock {
            var result: [AttentionEvent] = []
            let files =
                (try? FileManager.default.contentsOfDirectory(
                    at: eventsDirectory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard fileDayIntersects(name: file.lastPathComponent, from: from, to: to) else {
                    continue
                }
                if let data = try? Data(contentsOf: file) {
                    result.append(
                        contentsOf: decodeEvents(data).compactMap { $0.clipped(from: from, to: to) }
                    )
                }
            }
            return result.sorted { $0.startedAt < $1.startedAt }
        }
    }

    private func fileDayIntersects(name: String, from: Date, to: Date) -> Bool {
        guard let dayStart = eventFileDayStart(name: name) else { return true }
        let coverageEnd = dayStart.addingTimeInterval(172_800)
        return dayStart < to && coverageEnd > from
    }

    private func eventFileDayStart(name: String) -> Date? {
        let parts = name.dropLast(".jsonl".count).split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
            let day = Int(parts[2]), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return AttentionPaths.utcCalendar.date(from: components)
    }

    public func startFocus(
        name: String, duration: TimeInterval, now: Date = Date()
    ) throws -> AttentionFocusSession {
        try withLock {
            try prepare()
            guard !FileManager.default.fileExists(atPath: activeFocusFile.path) else {
                throw AttentionRepositoryError.focusAlreadyActive
            }
            let session = AttentionFocusSession(
                name: name, startedAt: now, plannedDuration: max(60, duration))
            try encoder.encode(session).write(to: activeFocusFile, options: .atomic)
            return session
        }
    }

    public func activeFocus() -> AttentionFocusSession? {
        withLock {
            guard let data = try? Data(contentsOf: activeFocusFile) else { return nil }
            return try? decoder.decode(AttentionFocusSession.self, from: data)
        }
    }

    public func endFocus(now: Date = Date()) throws -> AttentionFocusSession {
        try withLock {
            try prepare()
            guard let data = try? Data(contentsOf: activeFocusFile),
                var session = try? decoder.decode(AttentionFocusSession.self, from: data)
            else { throw AttentionRepositoryError.noActiveFocus }
            session.endedAt = max(now, session.startedAt)
            try appendLine(session, to: focusHistoryFile)
            try FileManager.default.removeItem(at: activeFocusFile)
            return session
        }
    }

    public func focusSessions(from: Date, to: Date) -> [AttentionFocusSession] {
        withLock {
            guard let data = try? Data(contentsOf: focusHistoryFile) else { return [] }
            return data.split(separator: 0x0A).compactMap {
                try? decoder.decode(AttentionFocusSession.self, from: Data($0))
            }.filter {
                $0.startedAt < to && ($0.endedAt ?? Date.distantFuture) > from
            }.sorted { $0.startedAt < $1.startedAt }
        }
    }

    public func hasEvents() -> Bool {
        withLock {
            guard
                let files = try? FileManager.default.contentsOfDirectory(
                    atPath: eventsDirectory.path)
            else { return false }
            return files.contains { $0.hasSuffix(".jsonl") }
        }
    }

    public func importHistory(_ visits: [AttentionHistoryVisit]) throws {
        try withLock {
            try prepare()
            let existing = historyVisitsUnlocked()
            var merged: [String: AttentionHistoryVisit] = [:]
            for visit in existing { merged[historyKey(visit)] = visit }
            for visit in visits { merged[historyKey(visit)] = visit }
            let values = merged.values.sorted { $0.lastVisitedAt > $1.lastVisitedAt }
            try encoder.encode(values).write(to: browserHistoryFile, options: .atomic)
        }
    }

    public func historyVisits() -> [AttentionHistoryVisit] {
        withLock { historyVisitsUnlocked() }
    }

    private func appendLine<T: Encodable>(_ value: T, to file: URL) throws {
        let line = try encoder.encode(value) + Data([0x0A])
        if !FileManager.default.fileExists(atPath: file.path) {
            try line.write(to: file, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(
            at: eventsDirectory, withIntermediateDirectories: true)
    }

    private func historyVisitsUnlocked() -> [AttentionHistoryVisit] {
        guard let data = try? Data(contentsOf: browserHistoryFile) else { return [] }
        return (try? decoder.decode([AttentionHistoryVisit].self, from: data)) ?? []
    }

    private func historyKey(_ visit: AttentionHistoryVisit) -> String {
        visit.profile + "\u{1F}" + visit.url
    }

    private func decodeEvents(_ data: Data) -> [AttentionEvent] {
        data.split(separator: 0x0A).compactMap {
            try? decoder.decode(AttentionEvent.self, from: Data($0))
        }
    }

    private func encodeLines(_ events: [AttentionEvent]) throws -> Data {
        try events.reduce(into: Data()) { result, event in
            result.append(try encoder.encode(event))
            result.append(0x0A)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(lockFile.path, O_RDONLY | O_CREAT, 0o644)
        guard descriptor >= 0 else { return try body() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return try body() }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}

public enum AttentionRepositoryError: LocalizedError, Equatable {
    case focusAlreadyActive
    case noActiveFocus

    public var errorDescription: String? {
        switch self {
        case .focusAlreadyActive: return "A focus session is already active."
        case .noActiveFocus: return "No focus session is active."
        }
    }
}
