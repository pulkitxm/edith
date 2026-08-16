import EdithKit
import Foundation

enum DockerLogDefaults {
    private static var store: UserDefaults { SharedDefaults.store }

    static var wrapLines: Bool {
        get { store.object(forKey: "dockerLogWrap") as? Bool ?? true }
        set { store.set(newValue, forKey: "dockerLogWrap") }
    }

    static var showTimestamps: Bool {
        get { store.object(forKey: "dockerLogTimestamps") as? Bool ?? false }
        set { store.set(newValue, forKey: "dockerLogTimestamps") }
    }

    static var fontSize: Double {
        get { store.object(forKey: "dockerLogFontSize") as? Double ?? 11 }
        set { store.set(newValue, forKey: "dockerLogFontSize") }
    }
}
