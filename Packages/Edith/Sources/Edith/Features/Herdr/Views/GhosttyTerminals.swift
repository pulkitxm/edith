import EdithKit
import Foundation

enum GhosttyTerminals {
    static var enabled: Bool {
        SharedDefaults.store.object(forKey: AppStorageKeys.Herdr.ghosttyTerminal) as? Bool ?? true
    }
}
