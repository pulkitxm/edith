public struct PasteQueue: Sendable, Equatable {
    public private(set) var entryIDs: [String] = []

    public init() {}

    public var count: Int { entryIDs.count }
    public var isEmpty: Bool { entryIDs.isEmpty }

    public mutating func enqueue(_ id: String) {
        entryIDs.append(id)
    }

    public mutating func dequeue() -> String? {
        entryIDs.isEmpty ? nil : entryIDs.removeFirst()
    }

    public mutating func remove(_ id: String) {
        entryIDs.removeAll { $0 == id }
    }

    public mutating func clear() {
        entryIDs.removeAll()
    }
}
