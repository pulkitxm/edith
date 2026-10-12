import EdithHostCore
import Foundation
import Observation

@MainActor @Observable final class HostSuiteSelection {
    private(set) var working = false
    private(set) var revision = 0
    private let marketplace: HostMarketplace
    private let defaults: UserDefaults

    init(marketplace: HostMarketplace, defaults: UserDefaults) {
        self.marketplace = marketplace; self.defaults = defaults
    }

    func enabled(_ suite: HostMarketplaceSuite) -> Bool {
        _ = revision
        return defaults.object(forKey: suite.defaultsKey) as? Bool
            ?? marketplace.entries.contains {
                $0.category == suite.id && marketplace.surfaceAvailability.activeIDs.contains($0.id)
            }
    }

    func setEnabled(_ enabled: Bool, suite: HostMarketplaceSuite) async {
        guard !working, marketplace.operationID == nil else { return }
        working = true
        defer { working = false; revision += 1 }
        let entries = marketplace.entries.filter { $0.category == suite.id }
        let allowed = Set(entries.map(\.id))
        let selectedKey = suite.defaultsKey + "Selections"
        let remembered = Set(defaults.stringArray(forKey: selectedKey) ?? []).intersection(allowed)
        if enabled {
            defaults.set(true, forKey: suite.defaultsKey)
            revision += 1
            for id in remembered.sorted() where marketplace.installed[id] != nil {
                await marketplace.enable(id: id)
                if marketplace.error != nil { break }
            }
        } else {
            let active = marketplace.surfaceAvailability.activeIDs.intersection(allowed)
            defaults.set(Array(remembered.union(active)).sorted(), forKey: selectedKey)
            marketplace.sessions.requestDisable(ids: active)
            defaults.set(false, forKey: suite.defaultsKey)
            revision += 1
            for id in active.sorted() {
                await marketplace.disable(id: id)
            }
        }
    }

    func select(_ entry: HostExtension, enabled: Bool) async {
        guard !working, marketplace.operationID == nil else { return }
        if enabled {
            await marketplace.enable(id: entry.id)
        } else {
            await marketplace.disable(id: entry.id)
        }
        guard let suite = HostMarketplaceCatalog.suites.first(where: { $0.id == entry.category })
        else { return }
        let key = suite.defaultsKey + "Selections"
        var selected = Set(defaults.stringArray(forKey: key) ?? [])
        if enabled, marketplace.surfaceAvailability.activeIDs.contains(entry.id) {
            selected.insert(entry.id); defaults.set(true, forKey: suite.defaultsKey)
        } else if !enabled {
            selected.remove(entry.id)
        }
        defaults.set(Array(selected).sorted(), forKey: key)
        revision += 1
    }
}
