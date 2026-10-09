import EdithExtensionUI
import EdithExtensionSupport
import Foundation

enum CompanionPaths {
    static var root: URL { ExtensionData.root }

    static let keychainService =
        (ProcessInfo.processInfo.environment["EDITH_APPLICATION_IDENTIFIER"]
            ?? "com.pulkit.edith.tests." + UUID().uuidString) + ".extensions.companion"
}
