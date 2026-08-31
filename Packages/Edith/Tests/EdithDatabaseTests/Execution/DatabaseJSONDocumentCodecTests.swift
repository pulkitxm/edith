import Foundation
import Testing

@testable import EdithDatabase

@Suite("Database JSON document codec")
struct DatabaseJSONDocumentCodecTests {
    @Test("Natural and extended JSON values round trip through bounded database values")
    func roundTrip() throws {
        let identifier = "507f1f77bcf86cd799439011"
        let source = """
            {
              "active": true,
              "count": 42,
              "identifier": {"$oid": "\(identifier)"},
              "nested": {"items": ["one", null, 3.5]}
            }
            """

        let decoded = try DatabaseJSONDocumentCodec.decode(source)
        let encoded = try DatabaseJSONDocumentCodec.encode(decoded)
        let roundTripped = try DatabaseJSONDocumentCodec.decode(encoded)

        #expect(roundTripped == decoded)
        guard case let .object(fields) = decoded else {
            Issue.record("expected an object")
            return
        }
        #expect(fields.first(where: { $0.name == "active" })?.value == .boolean(true))
        #expect(fields.first(where: { $0.name == "count" })?.value == .signedInteger(42))
        #expect(
            fields.first(where: { $0.name == "identifier" })?.value
                == .productSpecific(
                    DatabaseProductValue(
                        product: .mongoDB,
                        typeName: "objectId",
                        textRepresentation: identifier)))
    }

    @Test("Document decoding rejects scalars and oversized input")
    func rejectsInvalidDocuments() {
        #expect(throws: DatabaseJSONDocumentCodecError.invalidDocument) {
            _ = try DatabaseJSONDocumentCodec.decodeObject("[1, 2, 3]")
        }
        #expect(throws: DatabaseJSONDocumentCodecError.resourceLimit) {
            _ = try DatabaseJSONDocumentCodec.decode(
                "{\"value\":\"\(String(repeating: "x", count: 1_048_576))\"}")
        }
    }

    @Test("Plain document decoding preserves search engine JSON objects")
    func plainDocument() throws {
        let fields = try DatabaseJSONDocumentCodec.decodePlainObject(
            """
            {"event":{"$date":"literal"},"identifier":{"$oid":"literal"}}
            """)
        #expect(
            fields.first(where: { $0.name == "event" })?.value
                == .object([
                    DatabaseObjectField(name: "$date", value: .string("literal"))
                ]))
        #expect(
            fields.first(where: { $0.name == "identifier" })?.value
                == .object([
                    DatabaseObjectField(name: "$oid", value: .string("literal"))
                ]))
    }
}
