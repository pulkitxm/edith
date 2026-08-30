import Foundation

public enum WindowsTerminalShell: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case gitBash
    case powerShell
    case windowsPowerShell
    case commandPrompt

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: "Automatic"
        case .gitBash: "Git Bash"
        case .powerShell: "PowerShell 7"
        case .windowsPowerShell: "Windows PowerShell"
        case .commandPrompt: "Command Prompt"
        }
    }
}

public enum WindowsTerminalCommands {
    public static func interactiveShell(
        _ shell: WindowsTerminalShell = .automatic, startingDirectory: String? = nil
    ) -> String {
        let directory = startingDirectory.map(PowerShell.literal) ?? "$null"
        return PowerShell.interactiveCommand(
            """
            $directory = \(directory)
            if ($null -ne $directory -and
                (Test-Path -LiteralPath $directory -PathType Container)) {
                Set-Location -LiteralPath $directory
            }
            \(launchScript(for: shell))
            """)
    }

    public static func availableShells() -> String {
        PowerShell.command(
            """
            $gitCandidates = @(
                (Join-Path $env:ProgramFiles 'Git/bin/bash.exe'),
                (Join-Path $env:LOCALAPPDATA 'Programs/Git/bin/bash.exe')
            )
            $gitBash = $gitCandidates | Where-Object {
                Test-Path -LiteralPath $_ -PathType Leaf
            } | Select-Object -First 1
            if ($null -ne $gitBash) { [Console]::Out.WriteLine('gitBash') }
            if ($null -ne (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
                [Console]::Out.WriteLine('powerShell')
            }
            if ($null -ne (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
                [Console]::Out.WriteLine('windowsPowerShell')
            }
            if ($null -ne (Get-Command cmd.exe -ErrorAction SilentlyContinue)) {
                [Console]::Out.WriteLine('commandPrompt')
            }
            """)
    }

    public static func parseAvailableShells(_ output: String) -> [WindowsTerminalShell] {
        let available = Set(
            output.split(whereSeparator: \.isNewline).compactMap {
                WindowsTerminalShell(rawValue: String($0).trimmingCharacters(in: .whitespaces))
            })
        return WindowsTerminalShell.allCases.filter { $0 != .automatic && available.contains($0) }
    }

    private static func launchScript(for shell: WindowsTerminalShell) -> String {
        switch shell {
        case .automatic:
            return """
                $gitCandidates = @(
                    (Join-Path $env:ProgramFiles 'Git/bin/bash.exe'),
                    (Join-Path $env:LOCALAPPDATA 'Programs/Git/bin/bash.exe')
                )
                $gitBash = $gitCandidates | Where-Object {
                    Test-Path -LiteralPath $_ -PathType Leaf
                } | Select-Object -First 1
                if ($null -ne $gitBash) {
                    $env:CHERE_INVOKING = '1'
                    & $gitBash --login -i
                    exit $LASTEXITCODE
                }
                $powerShell = Get-Command pwsh.exe -ErrorAction SilentlyContinue |
                    Select-Object -First 1 -ExpandProperty Source
                if ($null -ne $powerShell) {
                    & $powerShell -NoLogo
                    exit $LASTEXITCODE
                }
                & powershell.exe -NoLogo
                exit $LASTEXITCODE
                """
        case .gitBash:
            return """
                $gitCandidates = @(
                    (Join-Path $env:ProgramFiles 'Git/bin/bash.exe'),
                    (Join-Path $env:LOCALAPPDATA 'Programs/Git/bin/bash.exe')
                )
                $gitBash = $gitCandidates | Where-Object {
                    Test-Path -LiteralPath $_ -PathType Leaf
                } | Select-Object -First 1
                if ($null -eq $gitBash) { throw 'Git Bash is not available.' }
                $env:CHERE_INVOKING = '1'
                & $gitBash --login -i
                exit $LASTEXITCODE
                """
        case .powerShell:
            return """
                $powerShell = Get-Command pwsh.exe -ErrorAction SilentlyContinue |
                    Select-Object -First 1 -ExpandProperty Source
                if ($null -eq $powerShell) { throw 'PowerShell 7 is not available.' }
                & $powerShell -NoLogo
                exit $LASTEXITCODE
                """
        case .windowsPowerShell:
            return """
                & powershell.exe -NoLogo
                exit $LASTEXITCODE
                """
        case .commandPrompt:
            return """
                & cmd.exe /Q /K
                exit $LASTEXITCODE
                """
        }
    }
}
