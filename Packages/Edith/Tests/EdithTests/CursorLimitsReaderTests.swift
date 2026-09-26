import Foundation
import SQLite3
import Testing

@testable import EdithKit

@Suite struct CursorLimitsReaderTests {
    @Test func planPercentAndOnDemandComeFromTheBillingCycle() throws {
        let data = Data(
            """
            {
              "billingCycleEnd": "1771077734000",
              "planUsage": { "totalPercentUsed": 15.48, "limit": 40000, "remaining": 16778 },
              "spendLimitUsage": { "individualLimit": 10000, "individualUsed": 2500, "pooledLimit": 0 }
            }
            """.utf8)
        let limits = try CursorLimitsReader.limits(json: data)
        #expect(limits.provider == .cursor)
        #expect(limits.week?.percent == 15.48)
        #expect(limits.week?.resetsAt == Date(timeIntervalSince1970: 1_771_077_734))
        #expect(limits.session?.percent == 25)
        #expect(limits.session?.resetsAt == limits.week?.resetsAt)
    }

    @Test func missingReportedPercentIsComputedFromTheIncludedAmount() throws {
        let data = Data(
            """
            { "billingCycleEnd": "2026-04-01T00:00:00Z", "planUsage": { "limit": 200, "remaining": 50 } }
            """.utf8)
        let limits = try CursorLimitsReader.limits(json: data)
        #expect(limits.week?.percent == 75)
        #expect(limits.session == nil)
        #expect(limits.week?.resetsAt == ISO8601DateFormatter().date(from: "2026-04-01T00:00:00Z"))
    }

    @Test func aPayloadWithoutPlanUsageIsUnavailable() {
        #expect(throws: CursorLimitsReader.Failure.unavailable) {
            try CursorLimitsReader.limits(json: Data("{}".utf8))
        }
    }

    @Test func authFileBeatsTheStateDatabase() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-limits-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let auth = home.appendingPathComponent(".cursor/auth.json")
        try FileManager.default.createDirectory(
            at: auth.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"accessToken":"file-token","refreshToken":"file-refresh"}"#.utf8).write(
            to: auth)
        let database = home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.writeDatabase(database, access: "db-token", refresh: "db-refresh")

        let material = try #require(CursorCredentialStore.load(home: home, environment: [:]))
        #expect(material.accessToken == "file-token")
        #expect(material.refreshToken == "file-refresh")
        #expect(material.file == auth)
    }

    @Test func stateDatabaseSuppliesATokenWhenNoAuthFileExists() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-limits-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let database = home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.writeDatabase(database, access: "db-token", refresh: "db-refresh")

        let material = try #require(CursorCredentialStore.load(home: home, environment: [:]))
        #expect(material.accessToken == "db-token")
        #expect(material.refreshToken == "db-refresh")
        #expect(material.file == nil)
    }

    @Test func expiryComesFromTheJwtAndRefreshIsDueInsideTheLeeway() {
        let soon = Date().addingTimeInterval(30)
        let later = Date().addingTimeInterval(600)
        let soonToken = Self.token(exp: soon.timeIntervalSince1970)
        let laterToken = Self.token(exp: later.timeIntervalSince1970)
        #expect(
            abs(
                (CursorCredentialStore.expiry(of: soonToken) ?? .distantPast).timeIntervalSince(
                    soon)) < 1)
        #expect(CursorCredentialStore.expiresSoon(soonToken))
        #expect(!CursorCredentialStore.expiresSoon(laterToken))
    }

    private static func token(exp: Double) -> String {
        let payload = Data("{\"exp\":\(exp)}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "x.\(payload).sig"
    }

    private static func writeDatabase(_ url: URL, access: String, refresh: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw CursorLimitsReader.Failure.unavailable
        }
        defer { sqlite3_close(handle) }
        let schema = "CREATE TABLE ItemTable (key TEXT, value TEXT)"
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            throw CursorLimitsReader.Failure.unavailable
        }
        let insert =
            "INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', ?), ('cursorAuth/refreshToken', ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, insert, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw CursorLimitsReader.Failure.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, access, -1, transient)
        sqlite3_bind_text(statement, 2, refresh, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CursorLimitsReader.Failure.unavailable
        }
    }
}
