import Foundation

public enum WindowsPowerProfileCommands {
    public static let status = PowerShell.command(
        """
        $active = powercfg.exe /getactivescheme 2>$null
        $activeMatch = [regex]::Match(($active -join ' '), `
            '[0-9a-fA-F-]{36}[^()]*[(](?<name>[^)]+)[)]')
        if (-not $activeMatch.Success) { exit 4 }
        [Console]::Out.WriteLine($activeMatch.Groups['name'].Value.Trim())
        powercfg.exe /list 2>$null | ForEach-Object {
            $match = [regex]::Match($_, '[0-9a-fA-F-]{36}[^()]*[(](?<name>[^)]+)[)]')
            if ($match.Success) {
                [Console]::Out.WriteLine($match.Groups['name'].Value.Trim())
            }
        }
        """)

    public static func parseStatus(_ output: String) -> MachinePlatformProfile? {
        let names = output.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let current = names.first else { return nil }
        let choices = names.dropFirst().reduce(into: [String]()) { result, name in
            if !result.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                result.append(name)
            }
        }
        guard choices.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame })
        else { return nil }
        return MachinePlatformProfile(current: current, choices: choices)
    }

    public static func setProfile(_ profile: String, durationSeconds: Int) -> String? {
        let selected = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, !selected.contains(where: \Character.isNewline),
            durationSeconds >= 0
        else { return nil }
        let selectedLiteral = PowerShell.literal(selected)
        let stopPrevious = """
            $statePath = Join-Path $env:LOCALAPPDATA 'Edith/power-profile-revert.json'
            if (Test-Path -LiteralPath $statePath) {
                $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                $process = Get-CimInstance Win32_Process `
                    -Filter "ProcessId = $([int]$state.ProcessId)" -ErrorAction SilentlyContinue
                if ($null -ne $process -and $process.CommandLine -like "*$($state.Encoded)*") {
                    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
                }
                Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
            }
            """
        let revert =
            durationSeconds > 0
            ? stopPrevious
                + """
                $stateDirectory = Split-Path -Parent $statePath
                New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
                $escapedStatePath = $statePath.Replace("'", "''")
                $revertScript = "Start-Sleep -Seconds \(durationSeconds); " +
                    "powercfg.exe /setactive $originalGuid; " +
                    "Remove-Item -LiteralPath '$escapedStatePath' -Force " +
                    "-ErrorAction SilentlyContinue"
                $bytes = [Text.Encoding]::Unicode.GetBytes($revertScript)
                $encoded = [Convert]::ToBase64String($bytes)
                $process = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                    '-EncodedCommand', $encoded)
                @{ ProcessId = $process.Id; Encoded = $encoded } | ConvertTo-Json |
                    Set-Content -LiteralPath $statePath
                """
            : stopPrevious
        return PowerShell.command(
            """
            $ErrorActionPreference = 'Stop'
            $requested = \(selectedLiteral)
            $active = powercfg.exe /getactivescheme
            $activeMatch = [regex]::Match(($active -join ' '), '(?<guid>[0-9a-fA-F-]{36})')
            if (-not $activeMatch.Success) { exit 4 }
            $originalGuid = $activeMatch.Groups['guid'].Value
            $selectedGuid = $null
            powercfg.exe /list | ForEach-Object {
                $match = [regex]::Match($_, `
                    '(?<guid>[0-9a-fA-F-]{36})[^()]*[(](?<name>[^)]+)[)]')
                if ($match.Success -and
                    $match.Groups['name'].Value.Trim() -ieq $requested) {
                    $selectedGuid = $match.Groups['guid'].Value
                }
            }
            if ($null -eq $selectedGuid) { exit 4 }
            powercfg.exe /setactive $selectedGuid
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            \(revert)
            [Console]::Out.WriteLine($requested)
            """)
    }
}
