import Foundation

public enum WindowsTerminalCommands {
    public static func interactiveShell(startingDirectory: String? = nil) -> String {
        let directory = startingDirectory.map(PowerShell.literal) ?? "$null"
        return PowerShell.interactiveCommand(
            """
            $directory = \(directory)
            if ($null -ne $directory -and
                (Test-Path -LiteralPath $directory -PathType Container)) {
                Set-Location -LiteralPath $directory
            }
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
            """)
    }
}
