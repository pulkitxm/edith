import EdithDatabase
import Foundation

func modelRoundTrip<Value: Codable>(_ value: Value) throws -> Value {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(Value.self, from: data)
}
