import EdithCore
import Foundation

public actor CalendarAgendaSnapshotStore {
    public static let standard = CalendarAgendaSnapshotStore(file: standardFile)

    public static var standardFile: URL {
        AppDirectories.current.data.appendingPathComponent("Snapshots/calendar-agenda.json")
    }

    private let file: URL
    private var memory: [CalendarEventPayload]?

    public init(file: URL) {
        self.file = file
    }

    public func load() -> [CalendarEventPayload]? {
        if let memory { return memory }
        guard let data = try? Data(contentsOf: file),
            let decoded = try? JSONDecoder().decode([CalendarEventPayload].self, from: data)
        else { return nil }
        memory = decoded
        return decoded
    }

    public func save(_ events: [CalendarEventPayload]) {
        memory = events
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
