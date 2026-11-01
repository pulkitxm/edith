import EdithExtensionUI
import Foundation

struct FinderDefaults {
    let store: UserDefaults

    var viewMode: String {
        get { store.string(forKey: "finderViewMode") ?? FileViewMode.list.rawValue }
        nonmutating set { store.set(newValue, forKey: "finderViewMode") }
    }

    var sortKey: String {
        get { store.string(forKey: "finderSortKey") ?? FileSortKey.name.rawValue }
        nonmutating set { store.set(newValue, forKey: "finderSortKey") }
    }

    var sortAscending: Bool {
        get { store.object(forKey: "finderSortAscending") as? Bool ?? true }
        nonmutating set { store.set(newValue, forKey: "finderSortAscending") }
    }

    var showHidden: Bool {
        get { store.object(forKey: "finderShowHidden") as? Bool ?? false }
        nonmutating set { store.set(newValue, forKey: "finderShowHidden") }
    }

    var iconSize: Double {
        get { store.object(forKey: "finderIconSize") as? Double ?? 72 }
        nonmutating set { store.set(newValue, forKey: "finderIconSize") }
    }
}
