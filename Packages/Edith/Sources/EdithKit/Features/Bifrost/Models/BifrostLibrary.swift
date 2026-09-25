import Foundation

public struct BifrostQuicklink: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var target: String
    public var keyword: String
    public var openWithBundleID: String?

    public init(
        id: String = UUID().uuidString, name: String, target: String, keyword: String = "",
        openWithBundleID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.keyword = keyword
        self.openWithBundleID = openWithBundleID
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var takesArgument: Bool {
        BifrostPlaceholder.usesQuery(target)
    }

    public func resolved(context: BifrostPlaceholderContext) -> String {
        let encoding: BifrostPlaceholderEncoding = isWebTarget ? .urlQuery : .plain
        return BifrostPlaceholder.expand(target, context: context, encoding: encoding)
    }

    public var isWebTarget: Bool {
        let lowered = target.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }
}

public struct BifrostSnippet: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var content: String
    public var keyword: String

    public init(
        id: String = UUID().uuidString, name: String, content: String, keyword: String = ""
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.keyword = keyword
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !content.isEmpty
    }

    public func resolved(context: BifrostPlaceholderContext) -> String {
        BifrostPlaceholder.expand(content, context: context)
    }

    public var preview: String {
        let collapsed = content.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 80 ? String(collapsed.prefix(79)) + "…" : collapsed
    }
}

public struct BifrostShellCommand: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var script: String
    public var keyword: String
    public var showsOutput: Bool

    public init(
        id: String = UUID().uuidString, name: String, script: String, keyword: String = "",
        showsOutput: Bool = true
    ) {
        self.id = id
        self.name = name
        self.script = script
        self.keyword = keyword
        self.showsOutput = showsOutput
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func resolved(context: BifrostPlaceholderContext) -> BifrostShellInvocation {
        BifrostPlaceholder.shell(script, context: context)
    }
}

public enum BifrostLibrary {
    public static func decode<Item: Decodable>(
        _ type: Item.Type, from text: String?
    ) -> [Item] {
        guard let text, let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    public static func encode<Item: Encodable>(_ items: [Item]) -> String {
        guard let data = try? JSONEncoder().encode(items),
            let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    public static func load<Item: Decodable>(
        _ type: Item.Type, key: String, defaults: UserDefaults = SharedDefaults.store
    ) -> [Item] {
        decode(type, from: defaults.string(forKey: key))
    }

    public static func save<Item: Encodable>(
        _ items: [Item], key: String, defaults: UserDefaults = SharedDefaults.store
    ) {
        defaults.set(encode(items), forKey: key)
    }
}
