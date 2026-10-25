import Foundation
import ObjectiveC

@MainActor
public enum ExtensionUIResources {
    private static var associationKey: UnsafeRawPointer {
        unsafeBitCast(NSSelectorFromString("edithExtensionUIOwnership"), to: UnsafeRawPointer.self)
    }

    public static func bind(_ bridge: NSObject, to owner: NSObject) {
        objc_setAssociatedObject(owner, associationKey, bridge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    public static func canDrainSharedResources(of owner: NSObject) -> Bool {
        guard let bridge = objc_getAssociatedObject(owner, associationKey) as? NSObject else {
            return true
        }
        let selector = NSSelectorFromString("canStopSharedResources")
        guard bridge.responds(to: selector) else { return false }
        typealias Check = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(bridge.method(for: selector), to: Check.self)(bridge, selector)
    }

    public static func cleanup(
        of owner: NSObject, key: String, operation: @escaping @MainActor () -> Void
    ) {
        guard let bridge = objc_getAssociatedObject(owner, associationKey) as? NSObject else {
            operation()
            return
        }
        let selector = NSSelectorFromString("scheduleSharedCleanup:operation:")
        guard bridge.responds(to: selector) else { return }
        typealias Schedule =
            @convention(c) (AnyObject, Selector, NSString, @convention(block) () -> Void) -> Void
        let callback: @convention(block) () -> Void = { MainActor.assumeIsolated { operation() } }
        unsafeBitCast(bridge.method(for: selector), to: Schedule.self)(
            bridge, selector, key as NSString, callback)
    }
}
