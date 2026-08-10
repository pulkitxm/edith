import Foundation

@MainActor
public protocol FeatureModule: AnyObject {
    init()
    func shutdown()
}
