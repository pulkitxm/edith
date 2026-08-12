import Foundation

public enum ShellProfile {
    public static let beginMarker = "# >>> edith completions >>>"
    public static let endMarker = "# <<< edith completions <<<"

    public static func file(
        for shell: CompletionScripts.Shell,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        switch shell {
        case .zsh: return home.appendingPathComponent(".zshrc")
        case .bash: return home.appendingPathComponent(".bashrc")
        case .fish: return nil
        }
    }

    public static func block(_ line: String) -> String {
        [beginMarker, line, endMarker].joined(separator: "\n")
    }

    public static func managedLine(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: beginMarker),
            let end = lines[start...].firstIndex(of: endMarker), end > start
        else { return nil }
        return lines[(start + 1)..<end].joined(separator: "\n")
    }

    public static func stripped(_ text: String, sourcing script: String? = nil) -> String {
        var lines = text.components(separatedBy: "\n")
        while let start = lines.firstIndex(of: beginMarker),
            let end = lines[start...].firstIndex(of: endMarker), end > start
        {
            lines.removeSubrange(start...end)
        }
        if let script {
            lines.removeAll { sourcesScript($0, script: script) }
        }
        return lines.joined(separator: "\n")
    }

    public static func sourcesScript(_ line: String, script: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("source ") || trimmed.hasPrefix(". ") else { return false }
        let name = (script as NSString).lastPathComponent
        return trimmed.hasSuffix(script) || trimmed.hasSuffix("/" + name)
    }

    public static func applying(_ line: String, to text: String, script: String? = nil) -> String {
        var body = stripped(text, sourcing: script)
        while body.hasSuffix("\n") { body.removeLast() }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return block(line) + "\n"
        }
        return body + "\n\n" + block(line) + "\n"
    }

    public static func removing(from text: String) -> String {
        var body = stripped(text)
        while body.hasSuffix("\n\n") { body.removeLast() }
        return body
    }

    @discardableResult
    public static func install(
        line: String, into file: URL, script: String? = nil,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let existing = fileManager.contents(atPath: file.path).map {
            String(decoding: $0, as: UTF8.self)
        }
        if let existing, managedLine(in: existing) == line,
            stripped(existing, sourcing: script) == stripped(existing)
        {
            return false
        }
        let updated = applying(line, to: existing ?? "", script: script)
        try Data(updated.utf8).write(to: file, options: .atomic)
        return true
    }

    @discardableResult
    public static func uninstall(from file: URL, fileManager: FileManager = .default) throws -> Bool
    {
        guard let data = fileManager.contents(atPath: file.path) else { return false }
        let existing = String(decoding: data, as: UTF8.self)
        guard managedLine(in: existing) != nil else { return false }
        try Data(removing(from: existing).utf8).write(to: file, options: .atomic)
        return true
    }
}
