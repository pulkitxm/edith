import Foundation

public enum HerdrAttachCommand {
    public static func line(for agent: HerdrAgent) -> String {
        if agent.isTerminal { return HerdrMachineTerminal.line(for: agent) }
        let attach = herdrLine(session: agent.session, pane: agent.pane)
        guard !agent.machineIsLocal, let target = agent.sshTarget, !target.isEmpty else {
            return attach
        }
        return "ssh -tt \(target) -- \(attach)"
    }

    public static func herdrLine(session: String, pane: String) -> String {
        "herdr --session \(session) agent attach \(pane) --takeover"
    }

    public static func remoteShellLine(
        session: String, pane: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        remoteHerdrCommand(
            arguments: arguments(session: session, pane: pane), platform: platform,
            interactive: true)
    }

    public static func arguments(session: String, pane: String) -> [String] {
        ["--session", session, "agent", "attach", pane, "--takeover"]
    }
}

public enum HerdrTerminalControlCommand {
    public static func arguments(session: String, pane: String) -> [String] {
        [
            "--session", session, "terminal", "session", "control", pane, "--takeover",
            "--cols", HerdrTerminalBridgeSpecification.columnsToken,
            "--rows", HerdrTerminalBridgeSpecification.rowsToken,
        ]
    }

    public static func remoteShellLine(
        session: String, pane: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        remoteHerdrCommand(
            arguments: arguments(session: session, pane: pane), platform: platform)
    }
}

public func remoteHerdrCommand(
    arguments: [String], platform: RemoteMachinePlatform, interactive: Bool = false
) -> String {
    let words = ["herdr"] + arguments
    if platform == .windows {
        let values = arguments.map(PowerShell.literal).joined(separator: ", ")
        let script = """
            $command = Get-Command herdr.exe -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty Source
            $installed = Join-Path $env:LOCALAPPDATA 'Programs/Herdr/bin/herdr.exe'
            $releaseRoot = Join-Path $env:USERPROFILE '.herdr/packages/standalone/releases'
            $release = Get-ChildItem -LiteralPath $releaseRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending |
                ForEach-Object { Join-Path $_.FullName 'herdr.exe' } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            $herdr = @($command, $installed, $release) | Where-Object {
                $null -ne $_ -and (Test-Path -LiteralPath $_ -PathType Leaf)
            } | Select-Object -First 1
            if ($null -eq $herdr) { throw 'herdr is not installed' }
            $arguments = @(\(values))
            & $herdr @arguments
            exit $LASTEXITCODE
            """
        return interactive
            ? PowerShell.interactiveCommand(script)
            : PowerShell.command(script)
    }
    let command = words.map(ShellQuote.quote).joined(separator: " ")
    return "export PATH=\"\(HerdrCollector.pathPrefix)\"; \(command)"
}
