import EdithKit
import ExtensionMarketplace
import Foundation

@MainActor
protocol KeepAwakeService: AnyObject {
    var preventingSleep: Bool { get }
    func syncPreventSleep()
    func shutdown()
}

@MainActor
final class KeepAwakeExtensionService: KeepAwakeService {
    private let runtime: ExtensionBundleRuntime
    private(set) var lastError: String?

    static func make() -> KeepAwakeExtensionService? {
        guard MarketplaceServices.installedPackage(id: "keepAwake") != nil else { return nil }
        do {
            let service = try KeepAwakeExtensionService(runtime: MarketplaceServices.helperRuntime)
            SharedDefaults.store.removeObject(forKey: "extension.keepAwake.runtimeError")
            return service
        } catch {
            SharedDefaults.store.set(
                error.localizedDescription, forKey: "extension.keepAwake.runtimeError")
            return nil
        }
    }

    init(runtime: ExtensionBundleRuntime) throws {
        self.runtime = runtime
        try runtime.start(
            id: "keepAwake", context: ["defaultsSuite": SharedDefaults.activeSuiteName])
    }

    var preventingSleep: Bool {
        (try? runtime.response(id: "keepAwake", operation: "status")["preventingSleep"] as? Bool)
            ?? false
    }

    func syncPreventSleep() {
        do { try runtime.synchronize(id: "keepAwake", context: [:]) } catch {
            lastError = error.localizedDescription
        }
    }

    func shutdown() {
        do { try runtime.stop(id: "keepAwake") } catch { lastError = error.localizedDescription }
    }
}
