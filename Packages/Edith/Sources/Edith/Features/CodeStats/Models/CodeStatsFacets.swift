import EdithKit
import Foundation

struct CodeStatsFacet: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let commits: Int
    let lines: Int
}

struct CodeStatsFacets: Equatable, Sendable {
    var repositories: [CodeStatsFacet] = []
    var owners: [CodeStatsFacet] = []
    var languages: [CodeStatsFacet] = []

    init() {}

    init(table: CodeStatsFactTable) {
        var repositoryTotals = [(commits: Int, lines: Int)](
            repeating: (0, 0), count: table.repositories.count)
        var languageTotals = [(commits: Int, lines: Int)](
            repeating: (0, 0), count: table.languages.count)
        for row in table.rows {
            let lines = row.counts.added + row.counts.updated
            if repositoryTotals.indices.contains(row.repository) {
                repositoryTotals[row.repository].commits += row.commits
                repositoryTotals[row.repository].lines += lines
            }
            if languageTotals.indices.contains(row.language) {
                languageTotals[row.language].commits += row.commits
                languageTotals[row.language].lines += lines
            }
        }
        var ownerTotals: [String: (commits: Int, lines: Int)] = [:]
        var repositories: [CodeStatsFacet] = []
        for (index, name) in table.repositories.enumerated() {
            let total = repositoryTotals[index]
            repositories.append(
                CodeStatsFacet(name: name, commits: total.commits, lines: total.lines))
            let owner = name.split(separator: "/", maxSplits: 1).first.map(String.init) ?? name
            ownerTotals[owner, default: (0, 0)].commits += total.commits
            ownerTotals[owner, default: (0, 0)].lines += total.lines
        }
        self.repositories = repositories.sorted { ($0.commits, $1.name) > ($1.commits, $0.name) }
        owners = ownerTotals.map {
            CodeStatsFacet(name: $0.key, commits: $0.value.commits, lines: $0.value.lines)
        }
        .sorted { ($0.commits, $1.name) > ($1.commits, $0.name) }
        var languages: [CodeStatsFacet] = []
        for (index, name) in table.languages.enumerated() {
            let total = languageTotals[index]
            languages.append(CodeStatsFacet(name: name, commits: total.commits, lines: total.lines))
        }
        self.languages = languages.sorted { ($0.lines, $1.name) > ($1.lines, $0.name) }
    }
}
