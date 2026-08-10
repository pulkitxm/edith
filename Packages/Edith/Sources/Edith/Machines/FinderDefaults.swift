import EdithKit
import Foundation

enum FinderDefaults {
    private static var store: UserDefaults { SharedDefaults.store }

    static var viewMode: String {
        get { store.string(forKey: "finderViewMode") ?? FileViewMode.list.rawValue }
        set { store.set(newValue, forKey: "finderViewMode") }
    }

    static var sortKey: String {
        get { store.string(forKey: "finderSortKey") ?? FileSortKey.name.rawValue }
        set { store.set(newValue, forKey: "finderSortKey") }
    }

    static var sortAscending: Bool {
        get { store.object(forKey: "finderSortAscending") as? Bool ?? true }
        set { store.set(newValue, forKey: "finderSortAscending") }
    }

    static var showHidden: Bool {
        get { store.object(forKey: "finderShowHidden") as? Bool ?? false }
        set { store.set(newValue, forKey: "finderShowHidden") }
    }

    static var iconSize: Double {
        get { store.object(forKey: "finderIconSize") as? Double ?? 72 }
        set { store.set(newValue, forKey: "finderIconSize") }
    }
}
