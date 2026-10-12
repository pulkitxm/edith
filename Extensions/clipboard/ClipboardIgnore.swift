import Foundation

public enum ClipboardIgnore {
    public static let knownPasswordManagers: Set<String> = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.lastpass.LastPass",
        "com.lastpass.lastpassmacdesktop",
        "com.dashlane.dashlanephonefinal",
        "com.bitwarden.desktop",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.nordpass.NordPass",
        "org.keepassxc.keepassxc",
        "com.enpass.desktop",
        "com.siber.roboform-mac",
        "com.strikesecurity.strikepass",
    ]

    public static func parseUserList(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func isIgnored(bundleID: String?, userList: [String]) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return knownPasswordManagers.contains(bundleID) || userList.contains(bundleID)
    }
}
