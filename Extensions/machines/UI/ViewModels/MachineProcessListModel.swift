import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation

enum MachineProcessProjection {
    static func build(
        _ processes: [MachineProcess], query: String, sortByMemory: Bool
    ) throws -> [MachineProcess] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [MachineProcess] = []
        rows.reserveCapacity(processes.count)
        for (index, process) in processes.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if query.isEmpty || process.name.localizedCaseInsensitiveContains(query)
                || process.cmd.localizedCaseInsensitiveContains(query)
                || process.user.localizedCaseInsensitiveContains(query)
                || String(process.pid).contains(query)
            {
                rows.append(process)
            }
        }
        rows.sort {
            let left = sortByMemory ? Double($0.rssKB) : $0.cpu
            let right = sortByMemory ? Double($1.rssKB) : $1.cpu
            return left == right ? $0.pid < $1.pid : left > right
        }
        try Task.checkCancellation()
        return rows
    }
}

@MainActor
@Observable
final class MachineProcessListModel {
    var query = ""
    var sortByMemory = false
    var selectedPID: Int?
    private(set) var rows: [MachineProcess] = []
    private(set) var totalCount = 0
    let loading = ContentLoad()

    func refresh(_ processes: [MachineProcess], debounce: Bool = true) async {
        let query = query
        let sortByMemory = sortByMemory
        await loading.perform(operation: {
            if debounce { try await Task.sleep(for: .milliseconds(80)) }
            return try MachineProcessProjection.build(
                processes, query: query, sortByMemory: sortByMemory)
        }) { rows in
            self.rows = rows
            totalCount = processes.count
            if let selectedPID, !rows.contains(where: { $0.pid == selectedPID }) {
                self.selectedPID = nil
            }
        }
    }
}
