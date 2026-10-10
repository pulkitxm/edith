import EdithExtensionSupport
import Foundation

public struct AgentApprovalInput: Equatable, Sendable {
    public struct Field: Equatable, Identifiable, Sendable {
        public var id: String
        public var value: String
        public var title: String { id.replacingOccurrences(of: "_", with: " ").capitalized }
    }
    public var fields: [Field]

    public init(_ raw: String) {
        guard let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
            let dictionary = object as? [String: Any], !dictionary.isEmpty
        else {
            fields = [Field(id: "details", value: raw)]
            return
        }
        let primary = ["command", "file_path", "path", "old_string", "new_string", "content"]
        let keys = dictionary.keys.sorted {
            let left = primary.firstIndex(of: $0) ?? primary.count
            let right = primary.firstIndex(of: $1) ?? primary.count
            return left == right ? $0 < $1 : left < right
        }
        fields = keys.compactMap { key in
            guard let value = dictionary[key] else { return nil }
            let text: String
            if let string = value as? String {
                text = string
            } else if let encoded = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys])
            {
                text = String(decoding: encoded, as: UTF8.self)
            } else {
                return nil
            }
            return Field(id: key, value: text)
        }
    }
}
