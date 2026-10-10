import EdithExtensionSupport
import Foundation

enum TerminalSettingsKeys {
    static let fontSize = "terminalFontSize"
    static let shell = "terminalShell"
    static let loginShell = "terminalLoginShell"
    static let startFolder = "terminalStartFolder"
    static let customFolder = "terminalCustomFolder"
    static let startupCommand = "terminalStartupCommand"
    static let confirmClose = "terminalConfirmClose"
}

struct TerminalSettings: Equatable, Sendable {
    enum StartFolder: String, CaseIterable, Sendable {
        case home
        case custom

        var title: String {
            switch self {
            case .home: "Home folder"
            case .custom: "Another folder"
            }
        }
    }

    static let fontSizeDefault = 13.0
    static let fontSizeRange = 9.0...24.0

    var fontSize: Double
    var shell: String
    var loginShell: Bool
    var startFolder: StartFolder
    var customFolder: String
    var startupCommand: String
    var confirmClose: Bool

    init(
        fontSize: Double = fontSizeDefault, shell: String = "", loginShell: Bool = true,
        startFolder: StartFolder = .home, customFolder: String = "", startupCommand: String = "",
        confirmClose: Bool = true
    ) {
        self.fontSize = Self.clampedFontSize(fontSize)
        self.shell = shell
        self.loginShell = loginShell
        self.startFolder = startFolder
        self.customFolder = customFolder
        self.startupCommand = startupCommand
        self.confirmClose = confirmClose
    }

    static func load(_ defaults: UserDefaults = SharedDefaults.store) -> Self {
        TerminalSettings(
            fontSize: defaults.object(forKey: TerminalSettingsKeys.fontSize) as? Double
                ?? fontSizeDefault,
            shell: defaults.string(forKey: TerminalSettingsKeys.shell)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            loginShell: defaults.object(forKey: TerminalSettingsKeys.loginShell) as? Bool ?? true,
            startFolder: defaults.string(forKey: TerminalSettingsKeys.startFolder)
                .flatMap(StartFolder.init(rawValue:)) ?? .home,
            customFolder: defaults.string(forKey: TerminalSettingsKeys.customFolder)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            startupCommand: defaults.string(forKey: TerminalSettingsKeys.startupCommand)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            confirmClose: defaults.object(forKey: TerminalSettingsKeys.confirmClose) as? Bool
                ?? true)
    }

    static func clampedFontSize(_ size: Double) -> Double {
        guard size.isFinite else { return fontSizeDefault }
        return min(fontSizeRange.upperBound, max(fontSizeRange.lowerBound, size.rounded()))
    }

    func shellPath(
        fileManager: FileManager = .default,
        loginShell fallback: () -> URL = UserShellEnvironment.loginShell
    ) -> String {
        let candidate = shell
        guard candidate.hasPrefix("/"), !candidate.utf8.contains(0),
            fileManager.isExecutableFile(atPath: candidate)
        else { return fallback().path }
        return candidate
    }

    func workingDirectory(
        home: String = NSHomeDirectory(), fileManager: FileManager = .default
    ) -> String {
        guard startFolder == .custom, !customFolder.isEmpty else { return home }
        let expanded = (customFolder as NSString).expandingTildeInPath
        var directory = ObjCBool(false)
        guard expanded.hasPrefix("/"),
            fileManager.fileExists(atPath: expanded, isDirectory: &directory),
            directory.boolValue
        else { return home }
        return expanded
    }
}
