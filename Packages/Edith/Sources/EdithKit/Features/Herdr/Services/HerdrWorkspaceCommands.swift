import Foundation

public enum HerdrWorkspaceCreateCommand {
    public static func arguments(label: String, cwd: String?) -> [String] {
        var args = ["workspace", "create", "--label", label, "--no-focus"]
        if let cwd, !cwd.isEmpty { args += ["--cwd", cwd] }
        return args
    }

    public static func shellLine(
        label: String, cwd: String?, platform: RemoteMachinePlatform = .linux
    ) -> String {
        remoteHerdrCommand(arguments: arguments(label: label, cwd: cwd), platform: platform)
    }
}

public enum HerdrTabCreateCommand {
    public static func arguments(workspaceID: String, cwd: String?) -> [String] {
        var args = ["tab", "create", "--workspace", workspaceID, "--no-focus"]
        if let cwd, !cwd.isEmpty { args += ["--cwd", cwd] }
        return args
    }

    public static func shellLine(
        workspaceID: String, cwd: String?, platform: RemoteMachinePlatform = .linux
    ) -> String {
        remoteHerdrCommand(
            arguments: arguments(workspaceID: workspaceID, cwd: cwd), platform: platform)
    }
}

public enum HerdrWorkspaceListCommand {
    public static let arguments = ["workspace", "list"]

    public static func shellLine(platform: RemoteMachinePlatform = .linux) -> String {
        remoteHerdrCommand(arguments: arguments, platform: platform)
    }
}

public enum HerdrAgentStartCommand {
    public static func name(_ base: String, pane: String) -> String {
        base + "-" + String(pane.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    public static func arguments(
        name: String, kindSlug: String, pane: String, timeoutMS: Int,
        agentArguments: [String] = []
    ) -> [String] {
        let start = [
            "agent", "start", name, "--kind", kindSlug, "--pane", pane, "--timeout",
            String(timeoutMS),
        ]
        return agentArguments.isEmpty ? start : start + ["--"] + agentArguments
    }

    public static func shellLine(
        name: String, kindSlug: String, pane: String, timeoutMS: Int,
        agentArguments: [String] = [], platform: RemoteMachinePlatform = .linux
    ) -> String {
        remoteHerdrCommand(
            arguments: arguments(
                name: name, kindSlug: kindSlug, pane: pane, timeoutMS: timeoutMS,
                agentArguments: agentArguments),
            platform: platform)
    }
}

public enum HerdrPaneRunCommand {
    public static func arguments(pane: String, command: String) -> [String] {
        ["pane", "run", pane, command]
    }

    public static func shellLine(
        pane: String, command: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        remoteHerdrCommand(arguments: arguments(pane: pane, command: command), platform: platform)
    }

    public static func commandText(
        _ command: String, appending agentArguments: [String],
        platform: RemoteMachinePlatform = .darwin
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !agentArguments.isEmpty else { return command }
        let quoted =
            platform == .windows
            ? agentArguments.map { PowerShell.literal(PowerShell.nativeArgument($0)) }
            : agentArguments.map(ShellQuote.quote)
        return ([trimmed] + quoted).joined(separator: " ")
    }
}
