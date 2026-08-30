import Foundation

public enum DockerCommands {
    public static let jsonFormat = "{{json .}}"
    public static let listSeparator = "@EDITHSPLIT@"

    public static func version(platform: RemoteMachinePlatform = .linux) -> String {
        host("docker version --format \(quote(jsonFormat, platform: platform)) 2>&1", platform)
    }

    public static func composeVersion(platform: RemoteMachinePlatform = .linux) -> String {
        host("docker compose version --short", platform)
    }

    public static func containersWithStats(
        platform: RemoteMachinePlatform = .linux
    ) -> String {
        let ps = "docker ps -a --no-trunc --format \(quote(jsonFormat, platform: platform))"
        let stats =
            "docker stats --no-stream --format \(quote(jsonFormat, platform: platform)) "
            + nullRedirect(platform)
        let separator =
            platform == .windows
            ? "Write-Output \(PowerShell.literal(listSeparator))"
            : "echo \(ShellQuote.quote(listSeparator))"
        return host("\(ps); \(separator); \(stats)", platform)
    }

    public static func images(platform: RemoteMachinePlatform = .linux) -> String {
        host("docker images --no-trunc --format \(quote(jsonFormat, platform: platform))", platform)
    }

    public static func volumes(platform: RemoteMachinePlatform = .linux) -> String {
        host("docker volume ls --format \(quote(jsonFormat, platform: platform))", platform)
    }

    public static func networks(platform: RemoteMachinePlatform = .linux) -> String {
        host("docker network ls --format \(quote(jsonFormat, platform: platform))", platform)
    }

    public static func diskUsage(platform: RemoteMachinePlatform = .linux) -> String {
        host("docker system df --format \(quote(jsonFormat, platform: platform))", platform)
    }

    public static func diskUsageVerbose(platform: RemoteMachinePlatform = .linux) -> String {
        host("docker system df -v --format \(quote(jsonFormat, platform: platform))", platform)
    }

    public static func inspect(
        _ id: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        host(
            "docker inspect --format \(quote(jsonFormat, platform: platform)) "
                + quote(id, platform: platform), platform)
    }

    public static func logs(
        _ id: String, tail: Int, follow: Bool,
        platform: RemoteMachinePlatform = .linux
    ) -> String {
        var command = "docker logs --timestamps --tail \(tail)"
        if follow { command += " --follow" }
        return host(command + " " + quote(id, platform: platform), platform)
    }

    public static func lifecycle(
        _ action: String, id: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        lifecycle(action, ids: [id], platform: platform)
    }

    public static func lifecycle(
        _ action: String, ids: [String], platform: RemoteMachinePlatform = .linux
    ) -> String {
        let targets = ids.map { quote($0, platform: platform) }.joined(separator: " ")
        let command: String
        switch action {
        case "stop", "restart":
            command = "docker \(action) -t 10 \(targets)"
        case "rm":
            command = "docker rm -f \(targets)"
        default:
            command = "docker \(action) \(targets)"
        }
        return host(command, platform)
    }

    public static func removeImage(
        _ id: String, force: Bool, platform: RemoteMachinePlatform = .linux
    ) -> String {
        host(
            "docker image rm \(force ? "-f " : "")\(quote(id, platform: platform))",
            platform)
    }

    public static func pullImage(
        _ reference: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        host("docker pull \(quote(reference, platform: platform))", platform)
    }

    public static func pruneImages(platform: RemoteMachinePlatform = .linux) -> String {
        host("docker image prune -f", platform)
    }

    public static func removeVolume(
        _ name: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        host("docker volume rm \(quote(name, platform: platform))", platform)
    }

    public static func pruneVolumes(platform: RemoteMachinePlatform = .linux) -> String {
        host("docker volume prune -f", platform)
    }

    public static func composeAction(
        _ action: String, project: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        host("docker compose -p \(quote(project, platform: platform)) \(action)", platform)
    }

    public static func execShell(
        containerID: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        let inner =
            "command -v bash >/dev/null 2>&1 && exec bash || exec sh"
        return host(
            "docker exec -it \(quote(containerID, platform: platform)) sh -c "
                + quote(inner, platform: platform), platform)
    }

    private static func host(_ script: String, _ platform: RemoteMachinePlatform) -> String {
        platform == .windows ? PowerShell.command(script) : script
    }

    private static func quote(_ value: String, platform: RemoteMachinePlatform) -> String {
        platform == .windows ? PowerShell.literal(value) : ShellQuote.quote(value)
    }

    private static func nullRedirect(_ platform: RemoteMachinePlatform) -> String {
        platform == .windows ? "2>$null" : "2>/dev/null"
    }
}

extension DockerCommands {
    public static func inspectRaw(
        _ id: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        host(
            "docker inspect \(quote(id, platform: platform)) \(nullRedirect(platform))",
            platform)
    }

    public static func top(
        _ id: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        let target = quote(id, platform: platform)
        let first = "docker top \(target) -eo pid,user,pcpu,pmem,rss,args \(nullRedirect(platform))"
        let fallback =
            platform == .windows
            ? "; if ($LASTEXITCODE -ne 0) { docker top \(target) }"
            : " || docker top \(target)"
        return host(first + fallback, platform)
    }

    public static func statsStream(platform: RemoteMachinePlatform = .linux) -> String {
        host("docker stats --format \(quote(jsonFormat, platform: platform))", platform)
    }

    public static func listFiles(
        containerID: String, path: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        let inner =
            "ls -lA --time-style=+%s \(ShellQuote.quote(path)) 2>/dev/null || ls -lA "
            + ShellQuote.quote(path)
        return host(
            "docker exec \(quote(containerID, platform: platform)) sh -c "
                + quote(inner, platform: platform), platform)
    }

    public static func readFile(
        containerID: String, path: String, limit: Int,
        platform: RemoteMachinePlatform = .linux
    ) -> String {
        let inner = "head -c \(limit) \(ShellQuote.quote(path))"
        return host(
            "docker exec \(quote(containerID, platform: platform)) sh -c "
                + quote(inner, platform: platform), platform)
    }

    public static func imageHistory(
        _ id: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        host(
            "docker image history --no-trunc --format \(quote(jsonFormat, platform: platform)) "
                + quote(id, platform: platform), platform)
    }

    public static func composeProjects(platform: RemoteMachinePlatform = .linux) -> String {
        host("docker compose ls --format json \(nullRedirect(platform))", platform)
    }

    public static func composeAction(
        _ action: String, project: String, directory: String?,
        platform: RemoteMachinePlatform = .linux
    )
        -> String
    {
        var command = "docker compose -p \(quote(project, platform: platform))"
        if let directory, !directory.isEmpty {
            command += " --project-directory \(quote(directory, platform: platform))"
        }
        return host(command + " " + action, platform)
    }

    public static func prune(
        _ what: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        let command: String
        switch what {
        case "images": command = "docker image prune -af"
        case "volumes": command = "docker volume prune -f"
        case "networks": command = "docker network prune -f"
        case "builder": command = "docker builder prune -af"
        default: command = "docker system prune -f"
        }
        return host(command, platform)
    }
}

public struct DockerProcess: Identifiable, Equatable, Sendable {
    public var pid: String
    public var user: String
    public var cpu: String
    public var memory: String
    public var command: String

    public var id: String { pid }

    public init(pid: String, user: String, cpu: String, memory: String, command: String) {
        self.pid = pid
        self.user = user
        self.cpu = cpu
        self.memory = memory
        self.command = command
    }
}

public struct DockerInspectSummary: Equatable, Sendable {
    public var image: String
    public var command: String
    public var created: String
    public var restartPolicy: String
    public var environment: [String]
    public var mounts: [String]
    public var networks: [String]
    public var labels: [String: String]

    public init(
        image: String = "", command: String = "", created: String = "",
        restartPolicy: String = "", environment: [String] = [], mounts: [String] = [],
        networks: [String] = [], labels: [String: String] = [:]
    ) {
        self.image = image
        self.command = command
        self.created = created
        self.restartPolicy = restartPolicy
        self.environment = environment
        self.mounts = mounts
        self.networks = networks
        self.labels = labels
    }
}

extension DockerParsing {
    public static func processes(_ output: String) -> [DockerProcess] {
        let lines = output.split(separator: "\n").map(String.init)
        guard let header = lines.first else { return [] }
        let columns = header.split(separator: " ", omittingEmptySubsequences: true).map {
            $0.uppercased()
        }
        guard columns.count > 1 else { return [] }
        func column(_ names: [String]) -> Int? {
            names.lazy.compactMap { columns.firstIndex(of: $0) }.first
        }
        let pidColumn = column(["PID"])
        let userColumn = column(["USER", "UID"])
        let cpuColumn = column(["%CPU", "C"])
        let memColumn = column(["%MEM"])
        let commandColumn = column(["COMMAND", "CMD", "ARGS"])
        return lines.dropFirst().compactMap { line in
            let parts = line.split(
                separator: " ", maxSplits: columns.count - 1, omittingEmptySubsequences: true
            ).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == columns.count else { return nil }
            func value(_ index: Int?) -> String {
                guard let index, index < parts.count else { return "" }
                return parts[index]
            }
            let pid = value(pidColumn)
            guard !pid.isEmpty else { return nil }
            return DockerProcess(
                pid: pid, user: value(userColumn), cpu: value(cpuColumn),
                memory: value(memColumn), command: value(commandColumn))
        }
    }

    public static func inspectSummary(_ output: String) -> DockerInspectSummary? {
        guard let data = output.data(using: .utf8),
            let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
            let object = array.first
        else { return nil }
        let config = object["Config"] as? [String: Any] ?? [:]
        let hostConfig = object["HostConfig"] as? [String: Any] ?? [:]
        let policy = hostConfig["RestartPolicy"] as? [String: Any] ?? [:]
        let networkSettings = object["NetworkSettings"] as? [String: Any] ?? [:]
        let networks = (networkSettings["Networks"] as? [String: Any])?.keys.sorted() ?? []
        let mounts = (object["Mounts"] as? [[String: Any]] ?? []).map { mount -> String in
            let source = string(mount, "Source")
            let destination = string(mount, "Destination")
            return source.isEmpty ? destination : "\(source) → \(destination)"
        }
        return DockerInspectSummary(
            image: string(config, "Image"),
            command: (config["Cmd"] as? [String] ?? []).joined(separator: " "),
            created: string(object, "Created"),
            restartPolicy: string(policy, "Name"),
            environment: config["Env"] as? [String] ?? [],
            mounts: mounts,
            networks: networks,
            labels: config["Labels"] as? [String: String] ?? [:])
    }

    public static func composeProjects(_ output: String) -> [String] {
        guard let data = output.data(using: .utf8) else { return [] }
        if let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            return array.map { string($0, "Name") }.filter { !$0.isEmpty }
        }
        return jsonLines(output).map { string($0, "Name") }.filter { !$0.isEmpty }
    }
}
