import Foundation
import EdithExtensionSupport

private final class MachineResourceToken {}

enum MachineResources {
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: ext)
        #else
        return Bundle(for: MachineResourceToken.self).url(forResource: name, withExtension: ext)
        #endif
    }
}
