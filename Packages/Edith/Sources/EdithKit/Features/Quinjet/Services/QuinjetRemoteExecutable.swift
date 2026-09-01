import Foundation

public struct QuinjetRemoteExecutableResolution: Equatable, Sendable {
    public let path: String?
    public let distributionID: String

    public init(path: String?, distributionID: String) {
        self.path = path
        self.distributionID = distributionID
    }
}

public enum QuinjetRemoteExecutableError: Error, Equatable, LocalizedError, Sendable {
    case probeFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case let .probeFailed(detail):
            return "Quinjet installation check failed: \(detail)"
        case .invalidResponse:
            return "Quinjet installation check returned an invalid response."
        }
    }
}

public enum QuinjetRemoteExecutable {
    private static let marker = "@EDITH_QUINJET@"

    public static func resolve(
        platform: RemoteMachinePlatform, connection: SSHConnection
    ) async throws -> QuinjetRemoteExecutableResolution {
        try await resolve(platform: platform) { command in
            try await connection.run(command, timeout: 20)
        }
    }

    static func resolve(
        platform: RemoteMachinePlatform,
        probe: @escaping @Sendable (String) async throws -> SSHExecResult
    ) async throws -> QuinjetRemoteExecutableResolution {
        let result: SSHExecResult
        do {
            result = try await probe(command(for: platform))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw QuinjetRemoteExecutableError.probeFailed(error.localizedDescription)
        }
        return try resolution(from: result, platform: platform)
    }

    static func resolution(
        from result: SSHExecResult, platform: RemoteMachinePlatform
    ) throws -> QuinjetRemoteExecutableResolution {
        guard result.succeeded else {
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail =
                stderr.isEmpty ? "remote command exited with status \(result.status)" : stderr
            throw QuinjetRemoteExecutableError.probeFailed(detail)
        }
        guard let resolution = parse(result.stdoutText, platform: platform) else {
            throw QuinjetRemoteExecutableError.invalidResponse
        }
        return resolution
    }

    public static func command(for platform: RemoteMachinePlatform) -> String {
        switch platform {
        case .darwin:
            unixCommand(
                distribution: "macos",
                candidates: [
                    "$HOME/.local/bin/quinjet", "$HOME/.cargo/bin/quinjet",
                    "/opt/homebrew/bin/quinjet", "/usr/local/bin/quinjet",
                    "$HOME/.nix-profile/bin/quinjet",
                    "/nix/var/nix/profiles/default/bin/quinjet", "/usr/bin/quinjet",
                ])
        case .linux:
            unixCommand(
                distribution:
                    "$(if [ -r /etc/os-release ]; then sed -n 's/^ID=//p' /etc/os-release | head -n 1 | tr -d '\"'; else printf linux; fi)",
                candidates: [
                    "$HOME/.local/bin/quinjet", "$HOME/.cargo/bin/quinjet",
                    "$HOME/.linuxbrew/bin/quinjet",
                    "/home/linuxbrew/.linuxbrew/bin/quinjet", "/usr/local/bin/quinjet",
                    "$HOME/.nix-profile/bin/quinjet",
                    "/nix/var/nix/profiles/default/bin/quinjet", "/usr/bin/quinjet",
                ])
        case .windows:
            PowerShell.command(
                #"""
                $resolved = $null
                $found = Get-Command quinjet.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -ne $found) { $resolved = $found.Source }
                if ([string]::IsNullOrWhiteSpace($resolved)) {
                    $candidates = @(
                        (Join-Path $env:LOCALAPPDATA 'Programs\Quinjet\bin\quinjet.exe'),
                        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\quinjet.exe'),
                        (Join-Path $env:USERPROFILE 'scoop\shims\quinjet.exe'),
                        (Join-Path $env:USERPROFILE '.local\bin\quinjet.exe'),
                        (Join-Path $env:ProgramFiles 'Quinjet\bin\quinjet.exe')
                    )
                    $resolved = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
                }
                if ($null -eq $resolved) { $resolved = '' }
                [Console]::Out.WriteLine('@EDITH_QUINJET@windows' + [char]9 + $resolved)
                """#)
        }
    }

    public static func parse(
        _ output: String, platform: RemoteMachinePlatform
    ) -> QuinjetRemoteExecutableResolution? {
        guard
            let line = output.components(separatedBy: .newlines).last(where: {
                $0.hasPrefix(marker)
            })
        else { return nil }
        let payload = line.dropFirst(marker.count)
        let fields = payload.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2 else { return nil }
        let distribution = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String?
        if candidate.isEmpty {
            path = nil
        } else if platform == .windows {
            guard FileListing.isWindowsPath(candidate) else { return nil }
            path = candidate
        } else {
            guard candidate.hasPrefix("/") else { return nil }
            path = candidate
        }
        return QuinjetRemoteExecutableResolution(
            path: path,
            distributionID: distribution.isEmpty ? defaultDistribution(for: platform) : distribution
        )
    }

    private static func unixCommand(distribution: String, candidates: [String]) -> String {
        let paths = candidates.map { "\"\($0)\"" }.joined(separator: " ")
        return """
            resolved=$(command -v quinjet 2>/dev/null || true)
            if [ -z "$resolved" ]; then
              for candidate in \(paths); do
                if [ -x "$candidate" ]; then resolved=$candidate; break; fi
              done
            fi
            distribution=\(distribution)
            printf '@EDITH_QUINJET@%s\t%s\n' "$distribution" "$resolved"
            """
    }

    private static func defaultDistribution(for platform: RemoteMachinePlatform) -> String {
        switch platform {
        case .darwin: "macos"
        case .linux: "linux"
        case .windows: "windows"
        }
    }
}
