import EdithKit
import Foundation

enum FinderListColumn: CaseIterable, Hashable {
    case modified
    case size
    case kind

    var width: Double {
        switch self {
        case .modified: 156
        case .size: 78
        case .kind: 92
        }
    }

    var title: String {
        switch self {
        case .modified: "Date Modified"
        case .size: "Size"
        case .kind: "Kind"
        }
    }

    var sortKey: FileSortKey {
        switch self {
        case .modified: .modified
        case .size: .size
        case .kind: .kind
        }
    }
}

struct FinderLayout: Equatable {
    static let sidebarWidth = 178.0
    static let sidebarMinimumWidth = 640.0
    static let compactToolbarWidth = 560.0
    static let nameMinimumWidth = 180.0
    static let rowChrome = 64.0
    static let columnSpacing = 10.0

    let showsSidebar: Bool
    let fitsSidebar: Bool
    let compactToolbar: Bool
    let columns: [FinderListColumn]

    init(width: Double, sidebarRequested: Bool, point: (Double) -> Double = UIScale.pt) {
        guard width > 0 else {
            fitsSidebar = true
            showsSidebar = sidebarRequested
            compactToolbar = false
            columns = FinderListColumn.allCases
            return
        }
        fitsSidebar = width >= point(Self.sidebarMinimumWidth)
        showsSidebar = sidebarRequested && fitsSidebar
        compactToolbar = width < point(Self.compactToolbarWidth)
        var remaining =
            width - (showsSidebar ? point(Self.sidebarWidth) : 0) - point(Self.rowChrome)
            - point(Self.nameMinimumWidth)
        var shown: Set<FinderListColumn> = []
        for column in FinderListColumn.allCases {
            let needed = point(column.width + Self.columnSpacing)
            guard remaining >= needed else { break }
            shown.insert(column)
            remaining -= needed
        }
        columns = FinderListColumn.allCases.filter(shown.contains)
    }
}
