import Foundation

public enum MachineWorkingDirectory {
    public static let sharedSessionKey = "shared"

    public static var root: URL { MachinePaths.dir.appendingPathComponent("cwd") }

    public static func sessionKey(descriptor: Int32 = STDIN_FILENO) -> String {
        guard isatty(descriptor) == 1, let name = ttyname(descriptor) else {
            return sharedSessionKey
        }
        return sanitize(String(cString: name))
    }

    public static func sanitize(_ tty: String) -> String {
        let stripped = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        let cleaned = stripped.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let key = String(cleaned)
        return key.isEmpty ? sharedSessionKey : key
    }

    public static func file(for machineID: UUID, session: String, in root: URL = root) -> URL {
        let hash = machineID.uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
        return root.appendingPathComponent(String(hash)).appendingPathComponent(session)
    }

    public static let previousMarker = "-"

    static func lines(
        machineID: UUID, session: String, fileManager: FileManager, root: URL = root
    ) -> [String] {
        let path = file(for: machineID, session: session, in: root)
        guard let data = fileManager.contents(atPath: path.path) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func load(
        machineID: UUID, session: String = sessionKey(), fileManager: FileManager = .default,
        root: URL = root
    ) -> String? {
        lines(machineID: machineID, session: session, fileManager: fileManager, root: root).first
    }

    public static func loadPrevious(
        machineID: UUID, session: String = sessionKey(), fileManager: FileManager = .default,
        root: URL = root
    ) -> String? {
        let found = lines(
            machineID: machineID, session: session, fileManager: fileManager, root: root)
        return found.count > 1 ? found[1] : nil
    }

    public static func resolvedDirectory(fromOutput output: String) -> String? {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    public static func save(
        _ directory: String, previous: String? = nil, machineID: UUID,
        session: String = sessionKey(), fileManager: FileManager = .default, root: URL = root
    ) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return clear(
                machineID: machineID, session: session, fileManager: fileManager, root: root)
        }
        let path = file(for: machineID, session: session, in: root)
        try? fileManager.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let body = [trimmed, previous?.trimmingCharacters(in: .whitespacesAndNewlines)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        try? Data(body.utf8).write(to: path, options: .atomic)
    }

    public static func clear(
        machineID: UUID, session: String = sessionKey(), fileManager: FileManager = .default,
        root: URL = root
    ) {
        try? fileManager.removeItem(at: file(for: machineID, session: session, in: root))
    }

    public static func prefixed(_ command: String, directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return command }
        return "cd " + ShellQuote.quote(directory) + " 2>/dev/null || cd; " + command
    }

    public static func resolveCommand(target: String?, from directory: String?) -> String {
        let base = directory.map { "cd " + ShellQuote.quote($0) + " 2>/dev/null; " } ?? ""
        guard let target, !target.isEmpty else { return base + "pwd; cd && pwd" }
        return base + "pwd; cd -- " + ShellQuote.quote(target) + " && pwd"
    }

    public static func originDirectory(fromOutput output: String) -> String? {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    public static func isChangeDirectory(_ words: [String]) -> Bool {
        words.first == "cd" && words.count <= 2
    }
}
