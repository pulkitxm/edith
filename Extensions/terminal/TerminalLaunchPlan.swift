import Foundation

struct TerminalLaunch: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String]
    let currentDirectory: String
    let startupCommand: String?
}

enum TerminalLaunchPlan {
    static let inheritedKeys = [
        "LOGNAME", "USER", "DISPLAY", "LC_TYPE", "HOME", "PATH", "SSH_AUTH_SOCK", "TMPDIR",
    ]
    static let nestingVariables = [
        "HERDR_ENV", "HERDR_PANE_ID", "HERDR_TAB_ID", "HERDR_WORKSPACE_ID",
    ]

    static func make(
        settings: TerminalSettings,
        base: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(), fileManager: FileManager = .default
    ) -> TerminalLaunch {
        let shell = settings.shellPath(fileManager: fileManager)
        return TerminalLaunch(
            executable: shell, arguments: settings.loginShell ? ["-l"] : [],
            environment: environment(base: base, shell: shell),
            currentDirectory: settings.workingDirectory(home: home, fileManager: fileManager),
            startupCommand: settings.startupCommand.isEmpty ? nil : settings.startupCommand)
    }

    static func environment(base: [String: String], shell: String) -> [String] {
        var values = [
            "TERM=xterm-256color", "COLORTERM=truecolor",
            "LANG=\(base["LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en_US.UTF-8")",
            "SHELL=\(shell)",
        ]
        for key in inheritedKeys {
            if let value = base[key], !value.utf8.contains(0) { values.append("\(key)=\(value)") }
        }
        let cleared = base.keys.filter { $0.hasPrefix("EDITH_") }.sorted() + nestingVariables
        return values + cleared.map { "\($0)=" }
    }
}
