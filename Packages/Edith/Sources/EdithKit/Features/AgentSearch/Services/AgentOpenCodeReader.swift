import Foundation
import SQLite3

enum AgentOpenCodeReader {
    struct Session: Equatable {
        let id: String
        let directory: String
        let title: String
        let updated: Double
    }

    static func database(home: URL, environment: [String: String]) -> URL {
        let data =
            environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/share")
        return data.appendingPathComponent("opencode/opencode.db")
    }

    static func sessions(in database: URL) -> [Session] {
        rows(
            in: database,
            sql: "select id, directory, coalesce(title, ''), time_updated from session_v2",
            bind: []
        ) { statement in
            Session(
                id: text(statement, 0), directory: text(statement, 1), title: text(statement, 2),
                updated: sqlite3_column_double(statement, 3) / 1_000)
        }
    }

    static func digest(for session: Session, in database: URL) -> AgentTranscriptDigest {
        var digest = AgentTranscriptDigest(
            path: database.path + "#" + session.id, kind: .opencode, sessionID: session.id)
        digest.cwd = session.directory
        if !session.title.isEmpty {
            digest.namedTitle = AgentTranscriptDigest.clean(
                session.title, limit: AgentTranscriptDigest.titleLimit)
        }
        let messages = rows(
            in: database,
            sql:
                "select type, data, time_created from session_message where session_id = ? order by seq",
            bind: [session.id]
        ) { statement in
            (text(statement, 0), text(statement, 1), sqlite3_column_double(statement, 2) / 1_000)
        }
        for (type, data, created) in messages {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(data.utf8))
                    as? [String: Any]
            else { continue }
            switch type {
            case "user":
                if let text = object["text"] as? String { digest.addPrompt(text) }
            case "assistant":
                for text in AgentTranscriptReader.texts(object["content"]) { digest.addReply(text) }
            default:
                continue
            }
            digest.touch(created)
        }
        return digest
    }

    private static func rows<Row>(
        in database: URL, sql: String, bind: [String], row: (OpaquePointer) -> Row
    ) -> [Row] {
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        var handle: OpaquePointer?
        guard
            sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let handle
        else { return [] }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bind.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        var found: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW { found.append(row(statement)) }
        return found
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
