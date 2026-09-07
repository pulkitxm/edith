import EdithKit
import Foundation
import GRDB

enum AgentEventJournal {
    static func load(store: AgentStore?) -> [AgentEvent] {
        guard let store else { return [] }
        return
            (try? store.read { database in
                try Data.fetchAll(
                    database, sql: "SELECT payload FROM agent_event ORDER BY sequence DESC LIMIT ?",
                    arguments: [AgentDiagnostics.capacity]
                ).reversed().compactMap { try? AgentPayload.decode(AgentEvent.self, from: $0) }
            }) ?? []
    }

    static func append(_ event: AgentEvent, store: AgentStore?) {
        guard let store else { return }
        do {
            let payload = try AgentPayload.encode(event)
            try store.write { database in
                try database.execute(
                    sql: "INSERT INTO agent_event (payload) VALUES (?)", arguments: [payload])
                try database.execute(
                    sql:
                        "DELETE FROM agent_event WHERE sequence <= (SELECT MAX(sequence) - ? FROM agent_event)",
                    arguments: [AgentDiagnostics.capacity])
            }
        } catch {
            AgentLog.logger.error(
                "Unable to save diagnostic event: \(error.localizedDescription, privacy: .private)")
        }
    }
}
