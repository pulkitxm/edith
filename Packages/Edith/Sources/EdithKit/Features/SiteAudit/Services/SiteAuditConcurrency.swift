import Foundation

public enum SiteAuditConcurrency {
    public static let limit = 4

    public static func slots(for count: Int, limit: Int = SiteAuditConcurrency.limit) -> Int {
        max(1, min(limit, count))
    }
}

public enum BoundedTaskRunner {
    public static func map<Element: Sendable, Result: Sendable>(
        _ elements: [Element], limit: Int,
        transform: @escaping @Sendable (Int, Element) async -> Result
    ) async -> [Result] {
        guard !elements.isEmpty else { return [] }
        let slots = SiteAuditConcurrency.slots(for: elements.count, limit: limit)
        var results = [Result?](repeating: nil, count: elements.count)
        await withTaskGroup(of: (Int, Result).self) { group in
            var next = 0
            for _ in 0..<slots {
                let index = next
                guard index < elements.count else { break }
                next += 1
                group.addTask { (index, await transform(index, elements[index])) }
            }
            while let (index, value) = await group.next() {
                results[index] = value
                guard next < elements.count, !Task.isCancelled else { continue }
                let following = next
                next += 1
                group.addTask { (following, await transform(following, elements[following])) }
            }
        }
        return results.compactMap { $0 }
    }
}
