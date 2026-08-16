import Foundation

public enum CompletionScripts {
    public enum Shell: String, CaseIterable, Sendable {
        case zsh
        case bash
        case fish

        public var scriptName: String {
            switch self {
            case .zsh: return "_ed"
            case .bash: return "ed"
            case .fish: return "ed.fish"
            }
        }
    }

    public static func script(for shell: Shell) -> String {
        script(for: shell, tool: toolPath())
    }

    public static func script(for shell: Shell, tool: String) -> String {
        let body =
            switch shell {
            case .zsh: zsh
            case .bash: bash
            case .fish: fish
            }
        return body.replacingOccurrences(of: toolPlaceholder, with: ShellQuote.quote(tool))
    }

    public static let toolPlaceholder = "@ED@"

    public static func toolPath(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String {
        let installed = CLIInstaller.preferredDirectory(home: home, fileManager: fileManager)
            .appendingPathComponent(CLIInstaller.primaryTool)
        if fileManager.isExecutableFile(atPath: installed.path) { return installed.path }
        if let bundled = CLIInstaller.bundledToolsDirectory(fileManager: fileManager)?
            .appendingPathComponent(CLIInstaller.primaryTool),
            fileManager.isExecutableFile(atPath: bundled.path)
        {
            return bundled.path
        }
        return CLIInstaller.primaryTool
    }

    public static let zsh = """
        #compdef ed edh edith

        _ed_complete() {
          local -a lines matches
          local line
          local -i wants_files=0
          local __ed=@ED@
          [[ -x $__ed ]] || __ed=ed
          lines=("${(@f)$($__ed __complete --index $((CURRENT-1)) -- "${words[@]}" 2>/dev/null)}")
          for line in "${lines[@]}"; do
            [[ -z "$line" ]] && continue
            if [[ "$line" == '#files' ]]; then
              wants_files=1
              continue
            fi
            matches+=("$line")
          done
          (( wants_files )) && _files
          (( ${#matches} )) && compadd -- "${matches[@]}"
        }

        if [[ $zsh_eval_context[-1] == loadautofunc ]]; then
          _ed_complete "$@"
        else
          compdef _ed_complete ed edh edith
        fi
        """

    public static let bash = """
        _ed_complete() {
          local IFS=$'\\n'
          local line
          local -a out
          COMPREPLY=()
          local __ed=@ED@
          [ -x "$__ed" ] || __ed=ed
          out=($("$__ed" __complete --index "$COMP_CWORD" -- "${COMP_WORDS[@]}" 2>/dev/null))
          for line in "${out[@]}"; do
            [ -z "$line" ] && continue
            if [ "$line" = '#files' ]; then
              COMPREPLY+=($(compgen -f -- "${COMP_WORDS[COMP_CWORD]}"))
              continue
            fi
            COMPREPLY+=("$line")
          done
        }

        complete -o bashdefault -F _ed_complete ed edh edith
        """

    public static let fish = """
        function __ed_complete
            set -l tokens (commandline -opc)
            set -l current (commandline -ct)
            set -l __ed @ED@
            test -x $__ed; or set __ed ed
            set -l out ($__ed __complete --index (count $tokens) -- $tokens $current 2>/dev/null)
            for line in $out
                if test "$line" = '#files'
                    __fish_complete_path $current
                else
                    echo $line
                end
            end
        end

        complete -c ed -f -a '(__ed_complete)'
        complete -c edh -f -a '(__ed_complete)'
        complete -c edith -f -a '(__ed_complete)'
        """

    public static func installDirectory(
        for shell: Shell, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if shell == .zsh, let existing = searchedZshDirectory(home: home) { return existing }
        return defaultDirectory(for: shell, home: home)
    }

    public static func defaultDirectory(
        for shell: Shell, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        return switch shell {
        case .zsh: home.appendingPathComponent(".local/share/zsh/site-functions")
        case .bash: home.appendingPathComponent(".local/share/bash-completion/completions")
        case .fish: home.appendingPathComponent(".config/fish/completions")
        }
    }

    public static func candidateDirectories(fromFpath output: String, home: URL) -> [URL] {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.hasPrefix(home.path) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func searchedZshDirectory(home: URL) -> URL? {
        fpathProbeCache.directory(forHome: home.path) { probeZshDirectory(home: home) }
    }

    public static func forgetProbedShellDirectories() {
        fpathProbeCache.forgetEverything()
    }

    static let fpathProbeCache = FpathProbeCache()

    private static func probeZshDirectory(home: URL) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ic", "print -l -- $fpath"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let manager = FileManager.default
        for directory in candidateDirectories(fromFpath: text, home: home) {
            var isDirectory: ObjCBool = false
            let exists = manager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue, manager.isWritableFile(atPath: directory.path) {
                return directory
            }
        }
        return nil
    }

    public static func sourceLine(forScript script: URL, home: URL) -> String {
        "source " + script.path.replacingOccurrences(of: home.path, with: "$HOME")
    }

    @discardableResult
    public static func linkFromProfile(
        _ shell: Shell, script: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let profile = ShellProfile.file(for: shell, home: home) else { return false }
        let line = sourceLine(forScript: script, home: home)
        return
            (try? ShellProfile.install(
                line: line, into: profile, script: script.path, fileManager: fileManager)) ?? false
    }

    public static func rcHint(for shell: Shell, directory: URL) -> String? {
        switch shell {
        case .zsh:
            guard
                searchedZshDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
                    != directory
            else { return nil }
            return "add to ~/.zshrc, before compinit: fpath=(\(directory.path) $fpath)"
        case .bash:
            return "add to ~/.bashrc: source \(directory.path)/ed"
        case .fish:
            return nil
        }
    }

    public static func sourceLine(
        for shell: Shell, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        store: UserDefaults = SharedDefaults.store, fileManager: FileManager = .default
    ) -> String {
        let file =
            existingFile(for: shell, home: home, store: store, fileManager: fileManager)
            ?? installDirectory(for: shell, home: home)
            .appendingPathComponent(shell.scriptName)
        return sourceLine(forScript: file, home: home)
    }

    @discardableResult
    public static func install(
        _ shell: Shell, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default, store: UserDefaults = SharedDefaults.store
    ) throws -> URL {
        let directory = installDirectory(for: shell, home: home)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(shell.scriptName)
        try Data(contents(for: shell).utf8).write(to: file, options: .atomic)
        record(file, for: shell, store: store)
        linkFromProfile(shell, script: file, home: home, fileManager: fileManager)
        forgetProbedShellDirectories()
        return file
    }

    public static let recordKey = "completionScriptPaths"
    public static let autoRefreshKey = "completionsAutoRefresh"

    public static func contents(for shell: Shell) -> String {
        script(for: shell) + "\n"
    }

    public static func isOurs(_ text: String) -> Bool {
        text.contains("__complete")
    }

    public static func isCurrent(
        _ file: URL, for shell: Shell, fileManager: FileManager = .default
    ) -> Bool {
        guard let data = fileManager.contents(atPath: file.path) else { return false }
        return String(decoding: data, as: UTF8.self) == contents(for: shell)
    }

    static func recordedPath(
        for shell: Shell, store: UserDefaults = SharedDefaults.store
    ) -> URL? {
        guard let paths = store.dictionary(forKey: recordKey) as? [String: String],
            let path = paths[shell.rawValue]
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func record(
        _ file: URL, for shell: Shell, store: UserDefaults = SharedDefaults.store
    ) {
        var paths = store.dictionary(forKey: recordKey) as? [String: String] ?? [:]
        paths[shell.rawValue] = file.path
        store.set(paths, forKey: recordKey)
    }

    @discardableResult
    public static func refreshInstalled(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default, store: UserDefaults = SharedDefaults.store
    ) -> [URL] {
        var written: [URL] = []
        for shell in detectShells(home: home, fileManager: fileManager) {
            if let recorded = recordedPath(for: shell, store: store),
                isCurrent(recorded, for: shell, fileManager: fileManager)
            {
                linkFromProfile(shell, script: recorded, home: home, fileManager: fileManager)
                continue
            }
            for target in refreshTargets(for: shell, home: home, fileManager: fileManager) {
                guard mayOverwrite(target, fileManager: fileManager) else { continue }
                try? fileManager.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard
                    (try? Data(contents(for: shell).utf8).write(to: target, options: .atomic))
                        != nil
                else { continue }
                written.append(target)
                record(target, for: shell, store: store)
                linkFromProfile(shell, script: target, home: home, fileManager: fileManager)
            }
        }
        return written
    }

    static func refreshTargets(
        for shell: Shell, home: URL, fileManager: FileManager = .default
    ) -> [URL] {
        var targets: [URL] = []
        let fallback = defaultDirectory(for: shell, home: home)
            .appendingPathComponent(shell.scriptName)
        if fileManager.fileExists(atPath: fallback.path) { targets.append(fallback) }
        let resolved = installDirectory(for: shell, home: home)
            .appendingPathComponent(shell.scriptName)
        if !targets.contains(where: { $0.path == resolved.path }) { targets.append(resolved) }
        return targets
    }

    static func mayOverwrite(_ file: URL, fileManager: FileManager = .default) -> Bool {
        guard let data = fileManager.contents(atPath: file.path) else { return true }
        return isOurs(String(decoding: data, as: UTF8.self))
    }

    public static func detectShells(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [Shell] {
        var found: [Shell] = [.zsh]
        if fileManager.fileExists(atPath: home.appendingPathComponent(".bashrc").path)
            || fileManager.fileExists(atPath: home.appendingPathComponent(".bash_profile").path)
        {
            found.append(.bash)
        }
        if fileManager.fileExists(atPath: home.appendingPathComponent(".config/fish").path) {
            found.append(.fish)
        }
        return found
    }
}

final class FpathProbeCache: @unchecked Sendable {
    static let lifetime: Duration = .seconds(30)

    private struct Probed {
        var directory: URL?
        var goesStaleAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var probed: [String: Probed] = [:]

    func directory(forHome home: String, whenStale probe: () -> URL?) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        if let entry = probed[home], entry.goesStaleAt > now { return entry.directory }
        let found = probe()
        probed[home] = Probed(
            directory: found, goesStaleAt: now.advanced(by: Self.lifetime))
        return found
    }

    func forgetEverything() {
        lock.lock()
        defer { lock.unlock() }
        probed.removeAll()
    }
}
