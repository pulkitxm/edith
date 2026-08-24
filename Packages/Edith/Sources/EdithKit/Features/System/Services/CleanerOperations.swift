import EdithCore
import Foundation

public enum CleanerOperation: String, CaseIterable, Sendable {
    case scan
    case clean

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "cleaner.\(rawValue)"), summary: summary,
            cli: ["cleaner", rawValue], effect: effect, requiresPreview: self == .clean)
    }

    private var summary: String {
        switch self {
        case .scan: "Measure reclaimable developer caches."
        case .clean: "Move reclaimable developer caches to the Trash."
        }
    }

    private var effect: UserOperationEffect {
        self == .scan ? .read : .destructive
    }
}

public struct CleanerScanResult: Sendable {
    public let categories: [JunkCategory]

    public init(categories: [JunkCategory]) {
        self.categories = categories
    }

    public var items: [JunkItem] { categories.flatMap(\.items) }
    public var totalBytes: Int64 { categories.reduce(0) { $0 + $1.sizeBytes } }
}

public struct CleanerCleanResult: Equatable, Sendable {
    public let items: Int
    public let requestedBytes: Int64
    public let reclaimedBytes: Int64

    public init(items: Int, requestedBytes: Int64, reclaimedBytes: Int64) {
        self.items = items
        self.requestedBytes = requestedBytes
        self.reclaimedBytes = reclaimedBytes
    }
}

public enum CleanerOperationExecution {
    public static func scan(
        entries: [JunkCatalog.Entry], roots: [URL] = [], only: String? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isCancelled: @escaping () -> Bool = { false },
        progress: @escaping (String) -> Void = { _ in }
    ) -> CleanerScanResult {
        var categories: [JunkCategory] = []
        for entry in entries {
            guard !isCancelled() else { break }
            progress(entry.name)
            if let category = JunkScanner.scanCategory(
                entry, home: home, isCancelled: isCancelled)
            {
                categories.append(category)
            }
        }
        if !roots.isEmpty, !isCancelled() {
            var projects = JunkScanner.scanProjectJunk(
                roots: roots, isCancelled: isCancelled, progress: progress)
            if let only { projects = projects.filter { $0.id == only } }
            categories.append(contentsOf: projects)
        }
        return CleanerScanResult(categories: categories)
    }

    public static func selectedItems(
        in categories: [JunkCategory], categoryID: String? = nil
    ) -> [JunkItem] {
        categories
            .filter { categoryID == nil || $0.id == categoryID }
            .flatMap { $0.items.filter(\.selected) }
    }

    public static func clean(
        _ items: [JunkItem], using reclaim: ([JunkItem]) -> Int64 = JunkScanner.clean
    ) -> CleanerCleanResult {
        CleanerCleanResult(
            items: items.count, requestedBytes: items.reduce(0) { $0 + $1.sizeBytes },
            reclaimedBytes: reclaim(items))
    }
}
