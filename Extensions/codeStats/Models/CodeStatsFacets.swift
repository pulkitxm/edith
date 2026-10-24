import EdithExtensionSupport
import EdithExtensionUI
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
        for fact in table.commits where fact.exclusion == nil {
            if repositoryTotals.indices.contains(fact.repository) {
                repositoryTotals[fact.repository].commits += 1
                repositoryTotals[fact.repository].lines += fact.authored
            }
            var touched = Set<Int>()
            for change in fact.changes where languageTotals.indices.contains(change.language) {
                languageTotals[change.language].lines += change.counts.authored
                if touched.insert(change.language).inserted {
                    languageTotals[change.language].commits += 1
                }
            }
        }
        var ownerTotals: [String: (commits: Int, lines: Int)] = [:]
        var repositories: [CodeStatsFacet] = []
        for (index, name) in table.repositories.enumerated()
        where repositoryTotals[index].commits > 0 {
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
        for (index, name) in table.languages.enumerated() where languageTotals[index].commits > 0 {
            let total = languageTotals[index]
            languages.append(CodeStatsFacet(name: name, commits: total.commits, lines: total.lines))
        }
        self.languages = languages.sorted { ($0.lines, $1.name) > ($1.lines, $0.name) }
    }
}
