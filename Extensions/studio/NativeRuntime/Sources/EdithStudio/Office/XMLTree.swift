import Foundation

public final class XMLTree {
    public let name: String
    public let attributes: [String: String]
    public private(set) var children: [XMLTree] = []
    public private(set) var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    public static func parse(_ data: Data, strict: Bool = false) -> XMLTree? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { return strict ? nil : builder.root }
        return builder.root
    }

    public func child(_ local: String) -> XMLTree? {
        children.first { $0.name == local }
    }

    public func all(_ local: String) -> [XMLTree] {
        children.filter { $0.name == local }
    }

    public func path(_ locals: String...) -> XMLTree? {
        var node: XMLTree? = self
        for local in locals { node = node?.child(local) }
        return node
    }

    public func first(_ local: String) -> XMLTree? {
        for child in children {
            if child.name == local { return child }
            if let found = child.first(local) { return found }
        }
        return nil
    }

    public func descendants(_ local: String) -> [XMLTree] {
        var result: [XMLTree] = []
        for child in children {
            if child.name == local { result.append(child) }
            result += child.descendants(local)
        }
        return result
    }

    public func attribute(_ local: String) -> String? {
        if let value = attributes[local] { return value }
        for (key, value) in attributes where key.hasSuffix(":" + local) { return value }
        return nil
    }

    public func number(_ local: String) -> Double? {
        attribute(local).flatMap(Double.init)
    }

    public var allText: String {
        text + children.map(\.allText).joined()
    }

    final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        var stack: [XMLTree] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let node = XMLTree(name: local, attributes: attributes)
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName: String?
        ) {
            stack.removeLast()
        }
    }
}
