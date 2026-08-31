import Testing

@testable import EdithDatabase

@Suite("Database connection URL parser")
struct DatabaseConnectionURLParserTests {
    @Test func parsesPostgreSQLCredentialsTLSAndDatabase() throws {
        let result = try DatabaseConnectionURLParser.parse(
            "postgresql://owner:p%40ss@db.example.com:6432/app?sslmode=require")

        #expect(result.product == .postgresql)
        #expect(result.host == "db.example.com")
        #expect(result.port == 6_432)
        #expect(result.username == "owner")
        #expect(result.password == "p@ss")
        #expect(result.database == "app")
        #expect(result.tlsEnabled)
        #expect(result.suggestedName == "app")
    }

    @Test func parsesPasswordOnlyRedisAndLogicalDatabase() throws {
        let result = try DatabaseConnectionURLParser.parse(
            "redis://default:secret@cache.example.com:15494/4")

        #expect(result.product == .redis)
        #expect(result.host == "cache.example.com")
        #expect(result.port == 15_494)
        #expect(result.username == "default")
        #expect(result.password == "secret")
        #expect(result.database == "4")
        #expect(!result.tlsEnabled)
    }

    @Test func parsesMongoAuthenticationSourceAndTLS() throws {
        let result = try DatabaseConnectionURLParser.parse(
            "mongodb://edith:secret@mongo.example.com/app?authSource=users&tls=true")

        #expect(result.product == .mongoDB)
        #expect(result.database == "app")
        #expect(result.authenticationDatabase == "users")
        #expect(result.tlsEnabled)
    }

    @Test func parsesSQLiteFileURL() throws {
        let result = try DatabaseConnectionURLParser.parse(
            "sqlite:///Users/me/Data/app.sqlite")

        #expect(result.product == .sqlite)
        #expect(result.path == "/Users/me/Data/app.sqlite")
        #expect(result.suggestedName == "app")
    }

    @Test func parsesElasticsearchHTTPURLForSelectedProduct() throws {
        let result = try DatabaseConnectionURLParser.parse(
            "http://127.0.0.1:59200",
            preferredProduct: .elasticsearch)

        #expect(result.product == .elasticsearch)
        #expect(result.host == "127.0.0.1")
        #expect(result.port == 59_200)
        #expect(result.username.isEmpty)
        #expect(result.password.isEmpty)
        #expect(!result.tlsEnabled)
    }

    @Test func parsesElasticsearchHTTPSCredentials() throws {
        let result = try DatabaseConnectionURLParser.parse(
            "https://edith:p%40ss@search.example.com",
            preferredProduct: .elasticsearch)

        #expect(result.product == .elasticsearch)
        #expect(result.username == "edith")
        #expect(result.password == "p@ss")
        #expect(result.port == 9_200)
        #expect(result.tlsEnabled)
    }

    @Test func rejectsUnsupportedAndSecureRedisSchemes() {
        #expect(throws: DatabaseConnectionURLError.unsupportedScheme("mysql")) {
            try DatabaseConnectionURLParser.parse("mysql://localhost/app")
        }
        #expect(throws: DatabaseConnectionURLError.secureRedisUnsupported) {
            try DatabaseConnectionURLParser.parse("rediss://localhost/0")
        }
        #expect(throws: DatabaseConnectionURLError.unsupportedScheme("http")) {
            try DatabaseConnectionURLParser.parse("http://localhost:9200")
        }
    }
}
