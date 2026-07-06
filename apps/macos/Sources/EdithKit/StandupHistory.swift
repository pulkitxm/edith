import Foundation

public enum StandupHistory {
    public struct Entry: Identifiable, Equatable {
        public let id: String
        public let date: Date
        public let content: String

        public init(id: String, date: Date, content: String) {
            self.id = id
            self.date = date
            self.content = content
        }
    }

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Standups")
    }

    public static func filePath(for date: Date, in directory: URL = Self.directory) -> URL {
        directory.appendingPathComponent("\(dayFormatter.string(from: date)).md")
    }

    public static func load(
        from directory: URL = Self.directory, fileManager: FileManager = .default
    )
        -> [Entry]
    {
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return
            files
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> Entry? in
                let name = url.deletingPathExtension().lastPathComponent
                guard let date = dayFormatter.date(from: name),
                    let content = try? String(contentsOf: url, encoding: .utf8)
                else { return nil }
                return Entry(id: name, date: date, content: content)
            }
            .sorted { $0.date > $1.date }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
