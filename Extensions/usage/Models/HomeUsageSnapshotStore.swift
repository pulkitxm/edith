import EdithExtensionSupport
import EdithExtensionUI
import Foundation

struct HomeUsageSnapshot: Codable, Equatable {
    var calendarDays: [DayPoint] = []
    var heatDetail: [String: HeatDay] = [:]
    var heatScale = UsageCalendarScale(days: [])

    var hasDays: Bool { !calendarDays.isEmpty }
}

actor HomeUsageSnapshotStore {
    static let standard = HomeUsageSnapshotStore(file: standardFile)

    static var standardFile: URL {
        ExtensionData.root.appendingPathComponent("Snapshots/home-usage.json")
    }

    private let file: URL
    private var memory: HomeUsageSnapshot?

    init(file: URL) {
        self.file = file
    }

    func load() -> HomeUsageSnapshot? {
        if let memory { return memory }
        guard let data = try? Data(contentsOf: file),
            let decoded = try? JSONDecoder().decode(HomeUsageSnapshot.self, from: data)
        else { return nil }
        memory = decoded
        return decoded
    }

    func store(_ snapshot: HomeUsageSnapshot) {
        memory = snapshot
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
