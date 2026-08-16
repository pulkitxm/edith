import Foundation

public enum DockerCommands {
    public static let jsonFormat = "{{json .}}"
    public static let listSeparator = "@EDITHSPLIT@"

    public static func version() -> String {
        "docker version --format \(ShellQuote.quote(jsonFormat)) 2>&1"
    }

    public static func composeVersion() -> String {
        "docker compose version --short"
    }

    public static func containersWithStats() -> String {
        let ps = "docker ps -a --no-trunc --format \(ShellQuote.quote(jsonFormat))"
        let stats =
            "docker stats --no-stream --format \(ShellQuote.quote(jsonFormat)) 2>/dev/null"
        return "\(ps); echo \(ShellQuote.quote(listSeparator)); \(stats)"
    }

    public static func images() -> String {
        "docker images --no-trunc --format \(ShellQuote.quote(jsonFormat))"
    }

    public static func volumes() -> String {
        "docker volume ls --format \(ShellQuote.quote(jsonFormat))"
    }

    public static func networks() -> String {
        "docker network ls --format \(ShellQuote.quote(jsonFormat))"
    }

    public static func diskUsage() -> String {
        "docker system df --format \(ShellQuote.quote(jsonFormat))"
    }

    public static func diskUsageVerbose() -> String {
        "docker system df -v --format \(ShellQuote.quote(jsonFormat))"
    }

    public static func inspect(_ id: String) -> String {
        "docker inspect --format \(ShellQuote.quote(jsonFormat)) \(ShellQuote.quote(id))"
    }

    public static func logs(_ id: String, tail: Int, follow: Bool) -> String {
        var command = "docker logs --timestamps --tail \(tail)"
        if follow { command += " --follow" }
        return command + " " + ShellQuote.quote(id)
    }

    public static func lifecycle(_ action: String, id: String) -> String {
        lifecycle(action, ids: [id])
    }

    public static func lifecycle(_ action: String, ids: [String]) -> String {
        let targets = ids.map(ShellQuote.quote).joined(separator: " ")
        switch action {
        case "stop", "restart":
            return "docker \(action) -t 10 \(targets)"
        case "rm":
            return "docker rm -f \(targets)"
        default:
            return "docker \(action) \(targets)"
        }
    }

    public static func removeImage(_ id: String, force: Bool) -> String {
        "docker image rm \(force ? "-f " : "")\(ShellQuote.quote(id))"
    }

    public static func pullImage(_ reference: String) -> String {
        "docker pull \(ShellQuote.quote(reference))"
    }

    public static func pruneImages() -> String {
        "docker image prune -f"
    }

    public static func removeVolume(_ name: String) -> String {
        "docker volume rm \(ShellQuote.quote(name))"
    }

    public static func pruneVolumes() -> String {
        "docker volume prune -f"
    }

    public static func composeAction(_ action: String, project: String) -> String {
        "docker compose -p \(ShellQuote.quote(project)) \(action)"
    }

    public static func execShell(containerID: String) -> String {
        let inner =
            "command -v bash >/dev/null 2>&1 && exec bash || exec sh"
        return "docker exec -it \(ShellQuote.quote(containerID)) sh -c \(ShellQuote.quote(inner))"
    }
}

extension DockerCommands {
    public static func inspectRaw(_ id: String) -> String {
        "docker inspect \(ShellQuote.quote(id)) 2>/dev/null"
    }

    public static func top(_ id: String) -> String {
        "docker top \(ShellQuote.quote(id)) -eo pid,user,pcpu,pmem,rss,args 2>/dev/null"
            + " || docker top \(ShellQuote.quote(id))"
    }

    public static func statsStream() -> String {
        "docker stats --format \(ShellQuote.quote(jsonFormat))"
    }

    public static func listFiles(containerID: String, path: String) -> String {
        let inner =
            "ls -lA --time-style=+%s \(ShellQuote.quote(path)) 2>/dev/null || ls -lA "
            + ShellQuote.quote(path)
        return "docker exec \(ShellQuote.quote(containerID)) sh -c \(ShellQuote.quote(inner))"
    }

    public static func readFile(containerID: String, path: String, limit: Int) -> String {
        let inner = "head -c \(limit) \(ShellQuote.quote(path))"
        return "docker exec \(ShellQuote.quote(containerID)) sh -c \(ShellQuote.quote(inner))"
    }

    public static func imageHistory(_ id: String) -> String {
        "docker image history --no-trunc --format \(ShellQuote.quote(jsonFormat)) "
            + ShellQuote.quote(id)
    }

    public static func composeProjects() -> String {
        "docker compose ls --format json 2>/dev/null"
    }

    public static func composeAction(_ action: String, project: String, directory: String?)
        -> String
    {
        var command = "docker compose -p \(ShellQuote.quote(project))"
        if let directory, !directory.isEmpty {
            command += " --project-directory \(ShellQuote.quote(directory))"
        }
        return command + " " + action
    }

    public static func prune(_ what: String) -> String {
        switch what {
        case "images": return "docker image prune -af"
        case "volumes": return "docker volume prune -f"
        case "networks": return "docker network prune -f"
        case "builder": return "docker builder prune -af"
        default: return "docker system prune -f"
        }
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
