import EdithKit
import Foundation
import GRDB

extension AttentionEventStore {
    public func deliver(_ request: AttentionDeliveryRequest, now: Date = Date()) throws {
        guard request.sequence > 0, !request.batch.events.isEmpty,
            request.batch.events.count <= 32,
            request.batch.events.allSatisfy({
                $0.duration.isFinite && $0.duration > 0 && $0.duration <= 172_800
            })
        else { throw AgentError(.refused, "Attention delivery is invalid.") }
        try store.write { database in
            let producer = request.producerID.uuidString
            let previous = try Int64.fetchOne(
                database,
                sql: "SELECT lastSequence FROM attention_delivery_receipt WHERE producerID = ?",
                arguments: [producer])
            if let previous {
                if request.sequence <= previous { return }
                guard previous < Int64.max, request.sequence == previous + 1 else {
                    throw AgentError(.refused, "Attention delivery is out of sequence.")
                }
            } else {
                try database.execute(
                    sql: "DELETE FROM attention_delivery_receipt WHERE updatedAt < ?",
                    arguments: [AttentionRetention.cutoff(now: now)])
                let count =
                    try Int.fetchOne(
                        database, sql: "SELECT COUNT(*) FROM attention_delivery_receipt") ?? 0
                guard count < 128 else {
                    throw AgentError(.unavailable, "Attention delivery receipt storage is full.")
                }
            }
            try record(request.batch, in: database, now: now)
            try database.execute(
                sql: """
                    INSERT INTO attention_delivery_receipt (producerID, lastSequence, updatedAt)
                    VALUES (?, ?, ?)
                    ON CONFLICT(producerID) DO UPDATE SET
                    lastSequence = excluded.lastSequence, updatedAt = excluded.updatedAt
                    """,
                arguments: [producer, request.sequence, now])
        }
    }
}
