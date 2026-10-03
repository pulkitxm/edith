import EdithKit
import Foundation

enum GhosttyTerminals {
    nonisolated(unsafe) static var defaults: UserDefaults = SharedDefaults.store

    static var enabled: Bool {
        defaults.object(forKey: AppStorageKeys.Herdr.ghosttyTerminal) as? Bool ?? true
    }
}
