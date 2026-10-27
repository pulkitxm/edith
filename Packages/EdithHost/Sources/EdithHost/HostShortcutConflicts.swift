import Carbon.HIToolbox
import EdithExtensionSupport
import Foundation

struct HostShortcutOwner: Equatable {
    let prefix: String
    let title: String
    let code: Int
    let modifiers: Int
}

enum HostShortcutConflicts {
    static func owner(
        code: Int, modifiers: Int, excluding prefix: String, among owners: [HostShortcutOwner]
    ) -> HostShortcutOwner? {
        owners.first {
            $0.prefix != prefix && $0.code == code && $0.modifiers == modifiers
        }
    }

    static func message(_ owner: HostShortcutOwner) -> String {
        "Already used by \(owner.title). Pick another shortcut."
    }

    static let panel = (
        prefix: "hotKey", title: "Open panel", code: kVK_ANSI_E, modifiers: optionKey | cmdKey
    )

    static func owner(
        title: String, prefix: String, defaultCode: Int, defaultModifiers: Int,
        defaults: UserDefaults
    ) -> HostShortcutOwner {
        HostShortcutOwner(
            prefix: prefix, title: title,
            code: defaults.object(forKey: prefix + "Code") as? Int ?? defaultCode,
            modifiers: defaults.object(forKey: prefix + "Mods") as? Int ?? defaultModifiers)
    }
}
