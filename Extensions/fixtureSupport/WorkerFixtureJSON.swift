import Foundation

public enum WorkerFixtureJSONError: Error { case invalid }

public enum WorkerFixtureJSON {
    public static func object(_ data: Data, maximumBytes: Int = 1_048_576) throws -> [String: Any] {
        guard maximumBytes > 0, maximumBytes <= 1_048_576, !data.isEmpty,
            data.count <= maximumBytes,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw WorkerFixtureJSONError.invalid }
        let bytes = Array(data)
        var index = 0
        var scopes: [Set<String>?] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 123 || byte == 91 {
                guard scopes.count < 64 else { throw WorkerFixtureJSONError.invalid }
                scopes.append(byte == 123 ? Set<String>() : nil)
            } else if byte == 125 || byte == 93 {
                guard !scopes.isEmpty else { throw WorkerFixtureJSONError.invalid }
                scopes.removeLast()
            } else if byte == 34 {
                let start = index
                index += 1
                while index < bytes.count && bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 }
                    index += 1
                }
                guard index < bytes.count else { throw WorkerFixtureJSONError.invalid }
                var next = index + 1
                while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count && bytes[next] == 58 {
                    guard !scopes.isEmpty, var names = scopes[scopes.count - 1],
                        let key = try JSONSerialization.jsonObject(
                            with: Data(bytes[start...index]), options: .fragmentsAllowed)
                            as? String,
                        names.insert(key).inserted
                    else { throw WorkerFixtureJSONError.invalid }
                    scopes[scopes.count - 1] = names
                }
            }
            index += 1
        }
        guard scopes.isEmpty else { throw WorkerFixtureJSONError.invalid }
        return object
    }
}
