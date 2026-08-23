import AppKit
import EdithKit
import SwiftUI

enum QuinjetTerminal: String, CaseIterable, Identifiable, Sendable {
    case embedded
    case cmux

    var id: String { rawValue }

    var label: String {
        switch self {
        case .embedded: "Embedded"
        case .cmux: "cmux"
        }
    }

    var icon: String {
        switch self {
        case .embedded: "rectangle.inset.filled"
        case .cmux: "macwindow.on.rectangle"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .embedded: true
        case .cmux: QuinjetCMUXLauncher.executable != nil
        }
    }
}

enum QuinjetTheme: String, CaseIterable, Identifiable, Sendable {
    case quinjet
    case catppuccin
    case dracula
    case everforest
    case gruvbox
    case nord
    case one
    case rosePine = "rose-pine"
    case solarized
    case tokyoNight = "tokyo-night"
    case ayu
    case monokai
    case github

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quinjet: "Quinjet"
        case .catppuccin: "Catppuccin"
        case .dracula: "Dracula"
        case .everforest: "Everforest"
        case .gruvbox: "Gruvbox"
        case .nord: "Nord"
        case .one: "One"
        case .rosePine: "Rosé Pine"
        case .solarized: "Solarized"
        case .tokyoNight: "Tokyo Night"
        case .ayu: "Ayu"
        case .monokai: "Monokai"
        case .github: "GitHub"
        }
    }
}

enum QuinjetAppearance: String, Sendable {
    case light
    case dark
}

struct QuinjetLaunchConfiguration: Equatable, Sendable {
    var terminal: QuinjetTerminal
    var theme: QuinjetTheme
    var appearance: QuinjetAppearance

    static let `default` = QuinjetLaunchConfiguration(
        terminal: .embedded, theme: .quinjet, appearance: .dark)
}

struct TerminalPalette {
    var background: NSColor
    var foreground: NSColor
    var caret: NSColor

    static func edith(dark: Bool) -> TerminalPalette {
        TerminalPalette(
            background: dark ? color(0x171412) : .white,
            foreground: dark ? color(0xebe6db) : .black,
            caret: dark ? color(0xd7a65c) : color(0x7a4f17))
    }

    static func quinjet(
        theme: QuinjetTheme, appearance: QuinjetAppearance
    ) -> TerminalPalette {
        let values = colors(theme: theme, appearance: appearance)
        return TerminalPalette(
            background: color(values.0), foreground: color(values.1), caret: color(values.2))
    }

    private static func colors(
        theme: QuinjetTheme, appearance: QuinjetAppearance
    ) -> (UInt32, UInt32, UInt32) {
        switch (theme, appearance) {
        case (.quinjet, .dark): (0x0d1117, 0xe6edf3, 0x58a6ff)
        case (.quinjet, .light): (0xffffff, 0x1f2328, 0x0969da)
        case (.catppuccin, .dark): (0x1e1e2e, 0xf5e0dc, 0x89b4fa)
        case (.catppuccin, .light): (0xeff1f5, 0x3c3f58, 0x1e66f5)
        case (.dracula, .dark): (0x282a36, 0xffffff, 0x66d9ef)
        case (.dracula, .light): (0xf8f8f2, 0x20212b, 0x005cc5)
        case (.everforest, .dark): (0x2d353b, 0xe4d9bd, 0x7fbbb3)
        case (.everforest, .light): (0xfdf6e3, 0x4b565c, 0x3a94c5)
        case (.gruvbox, .dark): (0x282828, 0xfbf1c7, 0x83a598)
        case (.gruvbox, .light): (0xfbf1c7, 0x282828, 0x458588)
        case (.nord, .dark): (0x2e3440, 0xe5e9f0, 0x81a1c1)
        case (.nord, .light): (0xeceff4, 0x2e3440, 0x426b94)
        case (.one, .dark): (0x282c34, 0xd7dae0, 0x61afef)
        case (.one, .light): (0xfafafa, 0x202227, 0x4078f2)
        case (.rosePine, .dark): (0x191724, 0xeeeaf4, 0xc4a7e7)
        case (.rosePine, .light): (0xfaf4ed, 0x403d52, 0x907aa9)
        case (.solarized, .dark): (0x002b36, 0xfdf6e3, 0x268bd2)
        case (.solarized, .light): (0xfdf6e3, 0x073642, 0x268bd2)
        case (.tokyoNight, .dark): (0x1a1b26, 0xd5d6db, 0x7aa2f7)
        case (.tokyoNight, .light): (0xe1e2e7, 0x2e3c64, 0x2e7de9)
        case (.ayu, .dark): (0x0b0e14, 0xe6e1cf, 0x59c2ff)
        case (.ayu, .light): (0xfafafa, 0x3f454a, 0x399ee6)
        case (.monokai, .dark): (0x272822, 0xf5f4f1, 0x66d9ef)
        case (.monokai, .light): (0xf9f8f5, 0x272822, 0x007fa3)
        case (.github, .dark): (0x0d1117, 0xf0f6fc, 0x2f81f7)
        case (.github, .light): (0xffffff, 0x24292f, 0x0969da)
        }
    }

    private static func color(_ value: UInt32) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
    }
}

private struct QuinjetLaunchConfigurationKey: EnvironmentKey {
    static let defaultValue = QuinjetLaunchConfiguration.default
}

extension EnvironmentValues {
    var quinjetLaunchConfiguration: QuinjetLaunchConfiguration {
        get { self[QuinjetLaunchConfigurationKey.self] }
        set { self[QuinjetLaunchConfigurationKey.self] = newValue }
    }
}

enum QuinjetLaunchError: LocalizedError {
    case cmuxUnavailable
    case cmuxLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .cmuxUnavailable: "cmux is not installed in Applications."
        case .cmuxLaunchFailed(let message): "cmux could not open Quinjet: \(message)"
        }
    }
}

enum QuinjetCMUXLauncher {
    static var executable: URL? {
        let candidates = [
            "/Applications/cmux.app/Contents/Resources/bin/cmux",
            "/Applications/cmux.app/Contents/MacOS/cmux",
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    static func launch(
        quinjet: URL, arguments: [String], currentDirectory: String?, replacing workspaceID: String?
    ) throws -> String {
        guard executable != nil else { throw QuinjetLaunchError.cmuxUnavailable }
        var command = "exec \(shellCommand(executable: quinjet.path, arguments: arguments))"
        if let currentDirectory {
            command = "cd \(shellQuote(currentDirectory)) && \(command)"
        }
        var statements = ["tell application id \"com.cmuxterm.app\"", "activate"]
        if let workspaceID {
            statements += closeStatements(workspaceID: workspaceID)
        }
        statements += [
            "set quinjetWorkspace to new tab",
            "select tab quinjetWorkspace",
            "delay 0.5",
            "set quinjetTerminal to focused terminal of quinjetWorkspace",
            "focus quinjetTerminal",
            "input text \(appleScriptQuote(command)) to quinjetTerminal",
            "perform action \(appleScriptQuote("text:\\x0d")) on quinjetTerminal",
            "return id of quinjetWorkspace",
            "end tell",
        ]
        return try execute(statements.joined(separator: "\n"))
    }

    static func focus(workspaceID: String) throws {
        let statements = [
            "tell application id \"com.cmuxterm.app\"", "activate",
            "repeat with cmuxWindow in windows",
            "repeat with cmuxWorkspace in tabs of cmuxWindow",
            "if id of cmuxWorkspace is \(appleScriptQuote(workspaceID)) then",
            "select tab cmuxWorkspace", "return id of cmuxWorkspace", "end if", "end repeat",
            "end repeat", "error \"workspace is no longer open\"", "end tell",
        ]
        _ = try execute(statements.joined(separator: "\n"))
    }

    static func close(workspaceID: String) throws {
        let statements =
            ["tell application id \"com.cmuxterm.app\""]
            + closeStatements(workspaceID: workspaceID) + ["return \"closed\"", "end tell"]
        _ = try execute(statements.joined(separator: "\n"))
    }

    static func shellCommand(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private static func closeStatements(workspaceID: String) -> [String] {
        [
            "repeat with cmuxWindow in windows",
            "repeat with cmuxWorkspace in tabs of cmuxWindow",
            "if id of cmuxWorkspace is \(appleScriptQuote(workspaceID)) then",
            "close tab cmuxWorkspace", "exit repeat", "end if", "end repeat", "end repeat",
        ]
    }

    private static func execute(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw QuinjetLaunchError.cmuxLaunchFailed("the launch request was invalid")
        }
        var details: NSDictionary?
        let result = script.executeAndReturnError(&details)
        if let details {
            let message = details[NSAppleScript.errorMessage] as? String ?? "unknown error"
            throw QuinjetLaunchError.cmuxLaunchFailed(message)
        }
        return result.stringValue ?? ""
    }
}
