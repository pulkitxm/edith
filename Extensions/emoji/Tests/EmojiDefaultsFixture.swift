import AppKit
import Foundation

final class EmojiDefaultsFixture {
    private let name = "com.pulkit.edith.tests.emoji." + UUID().uuidString
    let defaults: UserDefaults
    let pasteboard: NSPasteboard

    init() {
        defaults = UserDefaults(suiteName: name)!
        pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
    }

    func writePasteboard(_ value: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
        pasteboard.releaseGlobally()
    }
}
