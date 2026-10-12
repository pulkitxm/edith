import Darwin
import Foundation

extension HostToolingCLI {
    public func refreshExistingCompletions(enabled: Bool) -> [URL] {
        guard enabled, FileManager.default.isExecutableFile(atPath: executable.path) else {
            return []
        }
        var refreshed: [URL] = []
        for shell in Shell.allCases {
            let file = completionFile(shell).standardizedFileURL
            guard file.resolvingSymlinksInPath() == file else { continue }
            let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            var before = stat()
            guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                before.st_uid == getuid(), before.st_nlink == 1,
                (0...65_536).contains(before.st_size)
            else { continue }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            guard let data = try? handle.readToEnd(), data.count <= 65_536,
                let text = String(data: data, encoding: .utf8),
                managedCompletion(text, shell: shell), text != script(shell) + "\n"
            else { continue }
            var current = stat()
            guard lstat(file.path, &current) == 0, current.st_dev == before.st_dev,
                current.st_ino == before.st_ino, current.st_size == before.st_size,
                current.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                current.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
            else { continue }
            do {
                try HostCoreFiles.write(Data((script(shell) + "\n").utf8), to: file)
                refreshed.append(file)
            } catch {}
        }
        return refreshed
    }

    private func managedCompletion(_ text: String, shell: Shell) -> Bool {
        let parts = (completionTemplate(shell) + "\n").components(separatedBy: "@ED@")
        guard parts.count == 2, text.hasPrefix(parts[0]), text.hasSuffix(parts[1]),
            text.count >= parts[0].count + parts[1].count + 2
        else { return false }
        let literal = String(text.dropFirst(parts[0].count).dropLast(parts[1].count))
        guard literal.first == "'", literal.last == "'" else { return false }
        let path = String(literal.dropFirst().dropLast()).replacingOccurrences(
            of: "'\\''", with: "'")
        return path.hasPrefix("/") && !path.utf8.contains(0) && !path.contains("\n")
            && !path.contains("\r") && Self.quote(path) == literal
    }
}
