import EdithExtensionSupport
import Foundation

public struct HostToolingCLI: Sendable {
    public let home: URL
    public let executable: URL
    public let directory: URL
    public let path: [String]

    public static func bundledLauncher() -> URL? {
        ["Contents/MacOS/ed", "Contents/Resources/ed-launcher"].map {
            Bundle.main.bundleURL.appendingPathComponent($0)
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.resolvingSymlinksInPath()
    }

    public init(home: URL, executable: URL, directory: URL? = nil, path: [String]) {
        self.home = home; self.executable = executable; self.path = path
        let system = URL(fileURLWithPath: "/usr/local/bin")
        self.directory =
            directory
            ?? (FileManager.default.isWritableFile(atPath: system.path)
                ? system : home.appendingPathComponent(".local/bin"))
    }

    public func execute(_ arguments: [String]) throws -> ExtensionCLIReply {
        guard let command = arguments.first else {
            throw HostCLIError.usage("Missing tooling command.")
        }
        var args = try HostCLIArguments(
            Array(arguments.dropFirst()), flags: ["--json"], options: ["--directory", "--shell"])
        let json = args.flags.contains("--json")
        switch command {
        case "install", "uninstall":
            try args.require(words: 0...0, flags: ["--json"], options: ["--directory"])
            let target =
                args.options["--directory"].map {
                    URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
                } ?? directory
            let result = try links(target: target, remove: command == "uninstall")
            if json { return try HostCLIOutput.json(result) }
            let names =
                result.object?[command == "install" ? "linked" : "removed"]?.array?.compactMap(
                    \.string) ?? []
            return try HostCLIOutput.text(
                names.isEmpty
                    ? "\(command == "install" ? "already installed in" : "nothing to remove in") \(target.path)"
                    : "\(command == "install" ? "linked" : "removed") \(names.joined(separator: ", ")) \(command == "install" ? "in" : "from") \(target.path)"
            )
        case "status":
            try args.require(words: 0...0, flags: ["--json"])
            let linked = ["ed", "edith"].filter { ownedLink(directory.appendingPathComponent($0)) }
            let completions = Shell.allCases.map { shell -> HostCLIJSON in
                let file = completionFile(shell)
                let contents = try? String(contentsOf: file, encoding: .utf8)
                return .object([
                    "shell": .string(shell.rawValue), "path": .string(file.path),
                    "state": .string(
                        contents == nil
                            ? "missing" : contents == script(shell) + "\n" ? "current" : "stale"),
                ])
            }
            let result: HostCLIJSON = .object([
                "tools": .object([
                    "directory": .string(directory.path), "linked": .strings(linked),
                    "missing": .strings(["ed", "edith"].filter { !linked.contains($0) }),
                    "onPath": .bool(onPath(directory)),
                    "bundled": .bool(FileManager.default.isExecutableFile(atPath: executable.path)),
                ]),
                "completions": .array(completions), "fallbackSource": .string(source(.zsh)),
            ])
            if json { return try HostCLIOutput.json(result) }
            let lines = completions.compactMap { $0.object }.map {
                "\($0["shell"]?.string ?? ""): \($0["state"]?.string ?? "") \($0["path"]?.string ?? "")"
            }
            return try HostCLIOutput.text(
                ([
                    "tools: " + (linked.isEmpty ? "none" : linked.joined(separator: ", ")),
                    "directory: " + directory.path,
                    "on PATH: " + (onPath(directory) ? "yes" : "no"),
                ] + lines + ["fallback: " + source(.zsh)]).joined(separator: "\n"))
        case "completions":
            let action = args.words.isEmpty ? "install" : args.words.removeFirst()
            if let shell = Shell(rawValue: action) {
                try args.require(words: 0...0)
                return try HostCLIOutput.text(script(shell))
            }
            try args.require(words: 0...0, flags: ["--json"], options: ["--shell"])
            let selected = try args.options["--shell"].map { value in
                guard let shell = Shell(rawValue: value.lowercased()) else {
                    throw HostCLIError.usage("Unsupported shell \(value).")
                }
                return shell
            }
            if action == "source" {
                let shell = selected ?? .zsh
                return json
                    ? try HostCLIOutput.json(
                        .object([
                            "shell": .string(shell.rawValue), "source": .string(source(shell)),
                        ])) : try HostCLIOutput.text(source(shell))
            }
            guard action == "install" else {
                throw HostCLIError.usage("Unknown completions command.")
            }
            let shells = selected.map { [$0] } ?? detectedShells()
            var installed: [HostCLIJSON] = [], failures: [HostCLIJSON] = []
            for shell in shells {
                do {
                    let file = completionFile(shell)
                    if FileManager.default.fileExists(atPath: file.path) {
                        let current = try String(contentsOf: file, encoding: .utf8)
                        guard current.contains("__complete") else {
                            throw HostCLIError.rejected(
                                "An unrelated completion file already exists.")
                        }
                    }
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data((script(shell) + "\n").utf8).write(to: file, options: .atomic)
                    try linkProfile(shell, script: file)
                    installed.append(
                        .object([
                            "shell": .string(shell.rawValue), "path": .string(file.path),
                            "hint": .null,
                        ]))
                } catch {
                    failures.append(
                        .object([
                            "shell": .string(shell.rawValue),
                            "message": .string(error.localizedDescription),
                        ]))
                }
            }
            let reply =
                json
                ? try HostCLIOutput.json(
                    .object([
                        "installed": .array(installed), "failures": .array(failures),
                        "succeeded": .bool(failures.isEmpty),
                    ]))
                : try HostCLIOutput.text(
                    installed.compactMap(\.object).map {
                        "\($0["shell"]?.string ?? ""): \($0["path"]?.string ?? "")"
                    }.joined(separator: "\n"))
            return try ExtensionCLIReply(
                stdout: reply.stdout,
                stderr: json
                    ? ""
                    : failures.compactMap(\.object).map {
                        "error: \($0["shell"]?.string ?? ""): \($0["message"]?.string ?? "")\n"
                    }.joined(), exitCode: failures.isEmpty ? 0 : 1)
        default: throw HostCLIError.usage("Unknown tooling command.")
        }
    }

    private func links(target: URL, remove: Bool) throws -> HostCLIJSON {
        let manager = FileManager.default
        if !remove {
            guard manager.isExecutableFile(atPath: executable.path) else {
                throw HostCLIError.rejected("The ed binary is not present in this build.")
            }
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
        }
        var changed: [String] = [], skipped: [String] = []
        for name in ["ed", "edith"] {
            let file = target.appendingPathComponent(name)
            let destination = try? manager.destinationOfSymbolicLink(atPath: file.path)
            if remove {
                guard ownedLink(file) else { continue }
                try manager.removeItem(at: file); changed.append(name)
            } else {
                if ownedLink(file) { continue }
                if destination != nil || manager.fileExists(atPath: file.path) {
                    skipped.append(name); continue
                }
                try manager.createSymbolicLink(at: file, withDestinationURL: executable);
                changed.append(name)
            }
        }
        if !skipped.isEmpty {
            throw HostCLIError.rejected(
                "Existing files are not managed by this Edith installation: "
                    + skipped.joined(separator: ", "))
        }
        return .object([
            "directory": .string(target.path), remove ? "removed" : "linked": .strings(changed),
            "skipped": .strings(skipped), "onPath": .bool(onPath(target)), "message": .null,
        ])
    }
    private func ownedLink(_ file: URL) -> Bool {
        guard
            let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)
        else { return false }
        let resolved = URL(
            fileURLWithPath: destination, relativeTo: file.deletingLastPathComponent()
        ).standardizedFileURL
        return resolved == executable.standardizedFileURL
    }
    private func onPath(_ directory: URL) -> Bool {
        path.contains {
            URL(fileURLWithPath: $0).standardizedFileURL == directory.standardizedFileURL
        }
    }
    public enum Shell: String, CaseIterable, Sendable { case zsh, bash, fish }
    public func completionFile(_ shell: Shell) -> URL {
        switch shell {
        case .zsh: home.appendingPathComponent(".local/share/zsh/site-functions/_ed")
        case .bash: home.appendingPathComponent(".local/share/bash-completion/completions/ed")
        case .fish: home.appendingPathComponent(".config/fish/completions/ed.fish")
        }
    }
    public func script(_ shell: Shell) -> String {
        let template =
            switch shell {
            case .zsh: Self.zsh;
            case .bash: Self.bash;
            case .fish: Self.fish
            }
        return template.replacingOccurrences(of: "@ED@", with: Self.quote(executable.path))
    }
    private func source(_ shell: Shell) -> String {
        "source " + Self.quote(completionFile(shell).path)
    }
    private func detectedShells() -> [Shell] {
        let manager = FileManager.default
        var result: [Shell] = [.zsh]
        if manager.fileExists(atPath: home.appendingPathComponent(".bashrc").path)
            || manager.fileExists(atPath: home.appendingPathComponent(".bash_profile").path)
        {
            result.append(.bash)
        }
        if manager.fileExists(atPath: home.appendingPathComponent(".config/fish").path) {
            result.append(.fish)
        }
        return result
    }
    private func linkProfile(_ shell: Shell, script: URL) throws {
        guard shell != .fish else { return }
        let profile = home.appendingPathComponent(shell == .zsh ? ".zshrc" : ".bashrc")
        let line = "source " + Self.quote(script.path)
        let previous =
            FileManager.default.fileExists(atPath: profile.path)
            ? try String(contentsOf: profile, encoding: .utf8) : ""
        if previous.split(separator: "\n").contains(Substring(line)) { return }
        try Data(
            (previous + (previous.isEmpty || previous.hasSuffix("\n") ? "" : "\n") + line + "\n")
                .utf8
        ).write(to: profile, options: .atomic)
    }
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static let zsh = """
        #compdef ed edith

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
          compdef _ed_complete ed edith
        fi
        """

    private static let bash = """
        _ed_complete() {
          local line
          COMPREPLY=()
          local __ed=@ED@
          [ -x "$__ed" ] || __ed=ed
          while IFS= read -r line; do
            [ -z "$line" ] && continue
            if [ "$line" = '#files' ]; then
              while IFS= read -r line; do
                COMPREPLY+=("$line")
              done < <(compgen -f -- "${COMP_WORDS[COMP_CWORD]}")
              continue
            fi
            COMPREPLY+=("$line")
          done < <("$__ed" __complete --index "$COMP_CWORD" -- "${COMP_WORDS[@]}" 2>/dev/null)
        }

        complete -o bashdefault -F _ed_complete ed edith
        """

    private static let fish = """
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
        complete -c edith -f -a '(__ed_complete)'
        """

}
