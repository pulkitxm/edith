import Foundation

public struct DocsSource: Codable, Sendable, Hashable {
    public let path: String
    public let markdown: String

    public init(path: String, markdown: String) {
        self.path = path
        self.markdown = markdown
    }
}

public struct DocsLibrary: Sendable {
    public static let resourceName = "cli-docs"
    public static let indexPath = "README.md"

    public let pages: [DocsPage]
    public let groups: [DocsGroup]
    public let commands: [DocsCommand]
    let search: DocsSearchIndex
    private let pageIndex: [String: Int]
    private let commandIndex: [String: Int]

    public init(sources: [DocsSource]) {
        let parsed = sources.map { DocsParser.page(path: $0.path, markdown: $0.markdown) }
        let index = Dictionary(
            parsed.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
        pages = parsed
        pageIndex = index
        groups = Self.makeGroups(parsed, index: index)
        let commands = DocsCommandIndexer(pages: parsed, index: index).commands()
        self.commands = commands
        commandIndex = Dictionary(
            commands.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
        search = DocsSearchIndex(commands: commands, pages: parsed, index: index)
    }

    public static func bundled() -> DocsLibrary? {
        guard let url = BundledResources.url(forResource: resourceName, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let sources = try? JSONDecoder().decode([DocsSource].self, from: data)
        else { return nil }
        return DocsLibrary(sources: sources)
    }

    public func page(_ path: String) -> DocsPage? {
        pageIndex[path].map { pages[$0] }
    }

    public func command(_ path: String) -> DocsCommand? {
        commandIndex[DocsCommandText.normalized(path)].map { commands[$0] }
    }

    public func location(forCommand raw: String) -> DocsLocation? {
        let path = DocsCommandText.normalized(raw)
        if let command = command(path) { return command.location }
        var words = path.split(separator: " ").map(String.init)
        while words.count > 1 {
            words.removeLast()
            guard let parent = command(words.joined(separator: " ")) else { continue }
            let home = page(parent.location.path).map { [$0] } ?? []
            return DocsCommandIndexer.mention(of: path, in: home)
                ?? DocsCommandIndexer.mention(of: path, in: pages) ?? parent.location
        }
        return nil
    }

    public func lookup(_ query: String) -> DocsLocation? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let path = parts.first ?? ""
        let anchor = parts.count > 1 ? parts[1] : nil
        for candidate in [path, path + ".md", path + "/README.md"] where page(candidate) != nil {
            return DocsLocation(path: candidate, anchor: anchor)
        }
        return location(forCommand: trimmed)
    }

    public func section(_ location: DocsLocation) -> String {
        guard let page = page(location.path) else { return "" }
        guard let anchor = location.anchor else { return page.title + " " + page.abstract }
        var collecting = false
        var text: [String] = []
        for block in page.blocks {
            if case .heading(let heading) = block {
                if collecting { break }
                collecting = heading.anchor == anchor
                if collecting { text.append(heading.text) }
                continue
            }
            if collecting, case .paragraph = block {
                text.append(block.plainText)
                break
            }
        }
        return text.joined(separator: " ")
    }

    public func pages(inGroup group: String?) -> [DocsPage] {
        guard let group, !group.isEmpty else { return groups.flatMap(\.pages) }
        let wanted = group.lowercased()
        return groups.first { $0.id == wanted }?.pages ?? []
    }

    static func makeGroups(_ pages: [DocsPage], index: [String: Int]) -> [DocsGroup] {
        let order = index[indexPath].map { linkOrder(pages[$0]) } ?? []
        let byGroup = Dictionary(grouping: pages, by: \.group)
        let names = byGroup.keys.sorted { left, right in
            let leftRank = left.isEmpty ? -1 : order.firstIndex(of: left) ?? Int.max
            let rightRank = right.isEmpty ? -1 : order.firstIndex(of: right) ?? Int.max
            return leftRank == rightRank ? left < right : leftRank < rightRank
        }
        return names.map { name in
            let members = byGroup[name] ?? []
            let readme = members.first { $0.path.hasSuffix(indexPath) }
            let linked = readme.map { linkOrder($0, pages: true) } ?? []
            let sorted = members.sorted { left, right in
                func rank(_ page: DocsPage) -> Int {
                    if page.path.hasSuffix(indexPath) { return -1 }
                    return linked.firstIndex(of: page.path) ?? Int.max
                }
                return rank(left) == rank(right) ? left.path < right.path : rank(left) < rank(right)
            }
            let title =
                name.isEmpty
                ? "Overview"
                : readme.map {
                    DocsCommandText.path(in: $0.title).map { String($0.dropFirst(3)) } ?? $0.title
                }
                    ?? name
            return DocsGroup(id: name, title: title, pages: sorted)
        }
    }

    static func linkOrder(_ page: DocsPage, pages: Bool = false) -> [String] {
        var order: [String] = []
        func visit(_ spans: [DocsSpan]) {
            for span in spans {
                guard case .page(let path, _) = span.link else { continue }
                let key = pages ? path : (path.split(separator: "/").first.map(String.init) ?? path)
                if !order.contains(key) { order.append(key) }
            }
        }
        func walk(_ blocks: [DocsBlock]) {
            for block in blocks {
                switch block {
                case .paragraph(let spans): visit(spans)
                case .list(let list): list.items.forEach(walk)
                case .table(let table): table.rows.forEach { $0.forEach(visit) }
                default: continue
                }
            }
        }
        walk(page.blocks)
        return order
    }
}

struct DocsCommandIndexer {
    enum Source: Int, Comparable {
        case title, heading, synopsis, table

        static func < (left: Source, right: Source) -> Bool { left.rawValue < right.rawValue }
    }

    struct Entry {
        var source: Source
        var summary: String
        var location: DocsLocation?
    }

    let pages: [DocsPage]
    let index: [String: Int]

    func commands() -> [DocsCommand] {
        var entries: [String: Entry] = [:]
        var order: [String] = []
        func record(_ path: String, _ source: Source, _ summary: String, _ location: DocsLocation?)
        {
            guard var entry = entries[path] else {
                entries[path] = Entry(source: source, summary: summary, location: location)
                order.append(path)
                return
            }
            if entry.summary.isEmpty { entry.summary = summary }
            if source < entry.source {
                entry.source = source
                entry.location = location ?? entry.location
                if !summary.isEmpty { entry.summary = summary }
            }
            entries[path] = entry
        }
        for page in pages {
            if let command = page.command {
                record(command, .title, Self.sentence(page.abstract), DocsLocation(path: page.path))
            }
            var anchor: String?
            var pendingHeading: String?
            for block in page.blocks {
                switch block {
                case .heading(let heading):
                    anchor = heading.level == 1 ? nil : heading.anchor
                    pendingHeading = nil
                    if heading.level > 1, heading.spans.count == 1,
                        heading.spans[0].style.contains(.code),
                        let command = DocsCommandText.path(in: heading.text)
                    {
                        pendingHeading = command
                        record(command, .heading, "", DocsLocation(path: page.path, anchor: anchor))
                    }
                case .paragraph(let spans):
                    if let command = pendingHeading {
                        record(command, .heading, Self.sentence(DocsSpan.plain(spans)), nil)
                        pendingHeading = nil
                    }
                case .code(_, let text):
                    guard let owner = page.command else { continue }
                    for line in text.split(separator: "\n") {
                        let segment = line.split(separator: "|").last.map(String.init) ?? ""
                        guard let command = DocsCommandText.synopsis(in: segment),
                            command == owner || command.hasPrefix(owner + " ")
                        else { continue }
                        record(
                            command, .synopsis, "", DocsLocation(path: page.path, anchor: anchor))
                    }
                case .table(let table):
                    let first = table.header.first.map(DocsSpan.plain)?.lowercased()
                    guard table.header.count == 2, first == "command" || first == "commands"
                    else { continue }
                    for row in table.rows {
                        guard let cell = row.first, cell.first?.style.contains(.code) == true,
                            let command = DocsCommandText.path(in: cell[0].text)
                        else { continue }
                        let summary = row.count > 1 ? DocsSpan.plain(row[1]) : ""
                        record(command, .table, Self.sentence(summary), nil)
                    }
                default:
                    continue
                }
            }
        }
        return order.compactMap { path in
            guard let entry = entries[path] else { return nil }
            let parent = parentPage(of: path)
            let location =
                entry.location ?? parent.flatMap { Self.mention(of: path, in: [$0]) }
                ?? Self.mention(of: path, in: pages) ?? parent.map { DocsLocation(path: $0.path) }
            guard let location else { return nil }
            if entry.source == .table, let parent, parent.path == location.path,
                !parent.path.hasSuffix(DocsLibrary.indexPath)
            {
                return nil
            }
            return DocsCommand(path: path, summary: entry.summary, location: location)
        }
    }

    func parentPage(of path: String) -> DocsPage? {
        var words = path.split(separator: " ").map(String.init)
        while words.count > 1 {
            words.removeLast()
            let parent = words.joined(separator: " ")
            if let page = pages.first(where: { $0.command == parent }) { return page }
        }
        return nil
    }

    static func mention(of command: String, in pages: [DocsPage]) -> DocsLocation? {
        for page in pages {
            var anchor: String?
            var fallback: DocsLocation?
            for block in page.blocks {
                if case .heading(let heading) = block {
                    anchor = heading.level == 1 ? nil : heading.anchor
                    continue
                }
                guard DocsCommandText.mentions(block.plainText, command) else { continue }
                let location = DocsLocation(path: page.path, anchor: anchor)
                let overview = anchor == "at-a-glance" || anchor == "commands"
                if case .table = block {
                    fallback = fallback ?? location
                } else if overview {
                    fallback = fallback ?? location
                } else {
                    return location
                }
            }
            if let fallback { return fallback }
        }
        return nil
    }

    static func sentence(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let end = flat.range(of: ". ") else { return flat }
        return String(flat[..<end.lowerBound]) + "."
    }
}
