import EdithDatabase
import Testing

@testable import Edith

@Suite("Database filter operator policy")
struct DatabaseFilterOperatorPolicyTests {
    @Test("Relational text fields expose LIKE and scalar operators")
    func relationalText() {
        let operators = DatabaseFilterOperatorPolicy.operators(
            product: .postgresql,
            field: field(type: "varchar", nullable: true))

        #expect(operators.contains(.contains))
        #expect(operators.contains(.notEqual))
        #expect(operators.contains(.between))
        #expect(operators.contains(.isNull))
        #expect(!operators.contains(.regularExpression))
        #expect(
            DatabaseFilterOperatorPolicy.title(product: .postgresql, operation: .contains)
                == "Contains (LIKE)")
    }

    @Test("Relational non-null booleans avoid irrelevant operations")
    func relationalBoolean() {
        let operators = DatabaseFilterOperatorPolicy.operators(
            product: .sqlite,
            field: field(type: "BOOLEAN", nullable: false))

        #expect(operators == [.equal, .notEqual, .in, .notIn])
    }

    @Test("MongoDB keeps null and missing semantics distinct")
    func mongoPresence() {
        let operators = DatabaseFilterOperatorPolicy.operators(
            product: .mongoDB,
            field: field(type: "array", nullable: true))

        #expect(operators == [.isNull, .isNotNull, .isMissing, .isNotMissing])
        #expect(!operators.contains(.regularExpression))
        #expect(!operators.contains(.fullText))
    }

    @Test("Search analyzed and exact text fields use different operations")
    func searchTextKinds() {
        let analyzed = DatabaseFilterOperatorPolicy.operators(
            product: .elasticsearch,
            field: field(type: "text", nullable: true))
        let exact = DatabaseFilterOperatorPolicy.operators(
            product: .openSearch,
            field: field(type: "keyword", nullable: true))

        #expect(analyzed == [.fullText, .isMissing, .isNotMissing])
        #expect(exact.contains(.regularExpression))
        #expect(exact.contains(.notEqual))
        #expect(!exact.contains(.fullText))
        #expect(!exact.contains(.isNull))
    }

    @Test("Search keyword is textual rather than numeric")
    func searchKeyword() {
        let field = field(type: "runtime:keyword", nullable: true)
        let operators = DatabaseFilterOperatorPolicy.operators(
            product: .elasticsearch,
            field: field)

        #expect(operators.contains(.contains))
        #expect(!operators.contains(.greaterThan))
        #expect(
            DatabaseFilterOperatorPolicy.supportsCaseSensitivity(
                product: .elasticsearch, field: field, operation: .equal))
    }

    @Test("ClickHouse exposes regex and token matching without fake missing checks")
    func clickHouseText() {
        let operators = DatabaseFilterOperatorPolicy.operators(
            product: .clickHouse,
            field: field(type: "Nullable(LowCardinality(String))", nullable: true))

        #expect(operators.contains(.regularExpression))
        #expect(operators.contains(.fullText))
        #expect(operators.contains(.isNull))
        #expect(!operators.contains(.isMissing))
        #expect(
            DatabaseFilterOperatorPolicy.title(product: .clickHouse, operation: .fullText)
                == "Contains token")
    }

    @Test("Redis exposes only key patterns and type equality")
    func redisFields() {
        let keyOperators = DatabaseFilterOperatorPolicy.operators(
            product: .redis,
            field: field(type: "bytes", nullable: false))
        let typeOperators = DatabaseFilterOperatorPolicy.operators(
            product: .valkey,
            field: field(type: "redis-type", nullable: false))

        #expect(keyOperators == [.equal, .contains, .startsWith, .endsWith])
        #expect(typeOperators == [.equal])
        #expect(!DatabaseFilterOperatorPolicy.supportsDisjunction(product: .redis))
    }

    @Test("Defaults follow native text behavior")
    func defaults() {
        #expect(
            DatabaseFilterOperatorPolicy.defaultOperator(
                product: .elasticsearch,
                field: field(type: "text", nullable: true)) == .fullText)
        #expect(
            DatabaseFilterOperatorPolicy.defaultOperator(
                product: .postgresql,
                field: field(type: "text", nullable: true)) == .contains)
        #expect(
            DatabaseFilterOperatorPolicy.defaultOperator(
                product: .redis,
                field: field(type: "redis-type", nullable: false)) == .equal)
    }

    private func field(
        type: String,
        nullable: Bool
    ) -> DatabaseFieldDescriptor {
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("value"),
            displayName: "value",
            typeName: type,
            isNullable: nullable,
            isSortable: true,
            isFilterable: true)
    }
}
