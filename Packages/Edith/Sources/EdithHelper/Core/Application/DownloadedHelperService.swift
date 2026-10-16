import EdithKit
import ExtensionMarketplace
import Foundation

@MainActor
final class DownloadedHelperService {
    let id: String

    init?(id: String) {
        self.id = id
        guard MarketplaceServices.installedPackage(id: id) != nil else { return nil }
        do {
            try MarketplaceServices.helperRuntime.start(id: id, context: [:])
            SharedDefaults.store.removeObject(forKey: "extension.\(id).runtimeError")
        } catch {
            SharedDefaults.store.set(
                error.localizedDescription, forKey: "extension.\(id).runtimeError")
            return nil
        }
    }

    func toggle() {
        do { _ = try MarketplaceServices.helperRuntime.response(id: id, operation: "toggle") } catch
        {
            SharedDefaults.store.set(
                error.localizedDescription, forKey: "extension.\(id).runtimeError")
        }
    }

    func pauseUntilShareEnds() { perform("pauseUntilShareEnds") }
    func pick() { perform("pick") }
    func registerHotKey() { syncSettings() }

    private func perform(_ operation: String) {
        do {
            _ = try MarketplaceServices.helperRuntime.response(id: id, operation: operation)
        } catch {
            SharedDefaults.store.set(
                error.localizedDescription, forKey: "extension.\(id).runtimeError")
        }
    }

    func applySettings() { syncSettings() }

    func syncSettings() {
        do { try MarketplaceServices.helperRuntime.synchronize(id: id, context: [:]) } catch {
            SharedDefaults.store.set(
                error.localizedDescription, forKey: "extension.\(id).runtimeError")
        }
    }

    func shutdown() {
        do { try MarketplaceServices.helperRuntime.stop(id: id) } catch {
            SharedDefaults.store.set(
                error.localizedDescription, forKey: "extension.\(id).runtimeError")
        }
    }
}
