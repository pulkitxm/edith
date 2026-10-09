import Foundation

private final class UsageResourceToken: NSObject {}

public enum UsageResources {
    public static var bundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle(for: UsageResourceToken.self)
        #endif
    }
}
