import Foundation

struct HerdrSessionFilterChip: Equatable, Identifiable, Sendable {
    enum Removal: Equatable, Sendable {
        case machine
        case kind(String)
        case grouping
    }

    var id: String
    var key: String
    var value: String
    var removal: Removal
    var accessibilityLabel: String
    var removeLabel: String
}

struct HerdrSessionFilterRow: Equatable, Identifiable, Sendable {
    enum Action: Equatable, Sendable {
        case machine(String)
        case agent(String)
        case grouping
        case space(String)
        case launch
        case clear
    }

    var id: String
    var section: String
    var title: String
    var action: Action
    var selected: Bool

    var accessibilityLabel: String {
        switch action {
        case .machine, .agent:
            selected ? "\(title), selected" : title
        case .grouping:
            selected ? "Group by space, on" : "Group by space"
        case .space:
            "Open \(title) in a new window"
        case .launch:
            "Edit launch settings"
        case .clear:
            "Clear filters"
        }
    }

    var toggles: Bool {
        switch action {
        case .machine, .agent, .grouping: true
        case .space, .launch, .clear: false
        }
    }
}

enum HerdrSessionFilters {
    static func chips(
        machineID: String, machineName: String, kinds: some Sequence<String>, groupsBySpace: Bool
    ) -> [HerdrSessionFilterChip] {
        var chips: [HerdrSessionFilterChip] = []
        if machineID != "all" {
            let name = machineName.isEmpty ? machineID : machineName
            chips.append(
                HerdrSessionFilterChip(
                    id: "machine",
                    key: "Machine",
                    value: name,
                    removal: .machine,
                    accessibilityLabel: "Machine is \(name)",
                    removeLabel: "Remove machine filter, \(name)"))
        }
        let ordered = kinds.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        for kind in ordered {
            chips.append(
                HerdrSessionFilterChip(
                    id: "kind:\(kind)",
                    key: "Agent",
                    value: kind,
                    removal: .kind(kind),
                    accessibilityLabel: "Agent is \(kind)",
                    removeLabel: "Remove agent filter, \(kind)"))
        }
        if groupsBySpace {
            chips.append(
                HerdrSessionFilterChip(
                    id: "grouping",
                    key: "Group",
                    value: "Space",
                    removal: .grouping,
                    accessibilityLabel: "Grouped by space",
                    removeLabel: "Stop grouping by space"))
        }
        return chips
    }

    static func summary(of chips: [HerdrSessionFilterChip]) -> String {
        guard !chips.isEmpty else { return "No filters" }
        return chips.map(\.accessibilityLabel).joined(separator: ", ")
    }

    static func rows(
        query: String,
        machines: [(id: String, name: String)],
        kinds: [String],
        machineID: String,
        selectedKinds: Set<String>,
        groupsBySpace: Bool,
        spaces: [(id: String, title: String)]
    ) -> [HerdrSessionFilterRow] {
        var rows: [HerdrSessionFilterRow] = []
        for machine in machines {
            rows.append(
                HerdrSessionFilterRow(
                    id: "machine:\(machine.id)",
                    section: "Machine",
                    title: machine.name,
                    action: .machine(machine.id),
                    selected: machine.id == machineID))
        }
        rows.append(
            HerdrSessionFilterRow(
                id: "agent:all",
                section: "Agent",
                title: "Any agent",
                action: .agent("all"),
                selected: selectedKinds.isEmpty))
        for kind in kinds {
            rows.append(
                HerdrSessionFilterRow(
                    id: "agent:\(kind)",
                    section: "Agent",
                    title: kind,
                    action: .agent(kind),
                    selected: selectedKinds.contains(kind)))
        }
        rows.append(
            HerdrSessionFilterRow(
                id: "grouping",
                section: "Display",
                title: "Group by space",
                action: .grouping,
                selected: groupsBySpace))
        for space in spaces {
            rows.append(
                HerdrSessionFilterRow(
                    id: "space:\(space.id)",
                    section: "Spaces",
                    title: space.title,
                    action: .space(space.id),
                    selected: false))
        }
        rows.append(
            HerdrSessionFilterRow(
                id: "launch",
                section: "Actions",
                title: "Edit launch settings",
                action: .launch,
                selected: false))
        if machineID != "all" || !selectedKinds.isEmpty || groupsBySpace {
            rows.append(
                HerdrSessionFilterRow(
                    id: "clear",
                    section: "Actions",
                    title: "Clear filters",
                    action: .clear,
                    selected: false))
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.section.localizedCaseInsensitiveContains(needle)
        }
    }

    static func highlight(_ current: Int, movingBy delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(count - 1, max(0, current + delta))
    }
}
