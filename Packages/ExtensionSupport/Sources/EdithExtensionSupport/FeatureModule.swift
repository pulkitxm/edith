import Foundation

@MainActor
public protocol FeatureModule: AnyObject {
    init()
    func prepareDisable() async throws
    func shutdown()
}

public extension FeatureModule {
    func prepareDisable() async throws {}
}
