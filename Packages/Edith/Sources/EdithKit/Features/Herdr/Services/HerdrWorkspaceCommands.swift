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
    public static func arguments(name: String, kindSlug: String, pane: String, timeoutMS: Int)
        -> [String]
    {
        [
            "agent", "start", name, "--kind", kindSlug, "--pane", pane, "--timeout",
            String(timeoutMS),
        ]
    }

    public static func shellLine(
        name: String, kindSlug: String, pane: String, timeoutMS: Int,
        platform: RemoteMachinePlatform = .linux
    ) -> String {
        remoteHerdrCommand(
            arguments: arguments(name: name, kindSlug: kindSlug, pane: pane, timeoutMS: timeoutMS),
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
}
