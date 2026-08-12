import Foundation

public enum DockerParsing {
    public static func jsonLines(_ output: String) -> [[String: Any]] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    public static func string(_ object: [String: Any], _ key: String) -> String {
        if let value = object[key] as? String { return value }
        if let value = object[key] as? Int { return String(value) }
        if let value = object[key] as? Double { return String(value) }
        return ""
    }

    public static func parseSize(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "N/A", trimmed != "--" else { return nil }
        let suffixes: [(String, Double)] = [
            ("PiB", 1_125_899_906_842_624), ("TiB", 1_099_511_627_776),
            ("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1024),
            ("PB", 1e15), ("TB", 1e12), ("GB", 1e9), ("MB", 1e6),
            ("kB", 1e3), ("KB", 1e3), ("B", 1),
        ]
        for (suffix, multiplier) in suffixes where trimmed.hasSuffix(suffix) {
            let number = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number) else { return nil }
            return Int64(value * multiplier)
        }
        return Double(trimmed).map { Int64($0) }
    }

    public static func parsePercent(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("%") else { return nil }
        return Double(trimmed.dropLast())
    }

    public static func parsePair(_ text: String) -> (Int64?, Int64?) {
        let parts = text.split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { return (nil, nil) }
        return (parseSize(parts[0]), parseSize(parts[1]))
    }

    public static func parsePorts(_ text: String) -> [DockerPortMapping] {
        var seen = Set<DockerPortMapping>()
        var mappings: [DockerPortMapping] = []
        for entry in text.split(separator: ",") {
            let part = entry.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            let sides = part.components(separatedBy: "->")
            let containerSide = sides.count == 2 ? sides[1] : sides[0]
            let containerParts = containerSide.split(separator: "/")
            guard let containerPort = Int(containerParts.first ?? "") else { continue }
            let proto = containerParts.count > 1 ? String(containerParts[1]) : "tcp"
            var hostIP: String?
            var hostPort: Int?
            if sides.count == 2 {
                let hostSide = sides[0]
                if let colon = hostSide.lastIndex(of: ":") {
                    hostIP = String(hostSide[..<colon])
                    hostPort = Int(hostSide[hostSide.index(after: colon)...])
                } else {
                    hostPort = Int(hostSide)
                }
            }
            let mapping = DockerPortMapping(
                hostIP: hostIP, hostPort: hostPort, containerPort: containerPort, proto: proto)
            let dedupeKey = DockerPortMapping(
                hostIP: nil, hostPort: hostPort, containerPort: containerPort, proto: proto)
            if seen.insert(dedupeKey).inserted {
                mappings.append(mapping)
            }
        }
        return mappings.sorted { lhs, rhs in
            (lhs.hostPort ?? Int.max, lhs.containerPort)
                < (rhs.hostPort ?? Int.max, rhs.containerPort)
        }
    }

    public static func parseLabels(_ text: String) -> [String: String] {
        var labels: [String: String] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            labels[String(parts[0])] = String(parts[1])
        }
        return labels
    }

    public static func parseHealth(status: String, healthStatus: String = "") -> DockerHealth {
        if let explicit = DockerHealth(rawValue: healthStatus.lowercased()) { return explicit }
        let lowered = status.lowercased()
        if lowered.contains("(healthy)") { return .healthy }
        if lowered.contains("(unhealthy)") { return .unhealthy }
        if lowered.contains("health: starting") { return .starting }
        return .none
    }

    public static func containers(psOutput: String) -> [DockerContainer] {
        jsonLines(psOutput).compactMap { object in
            let id = string(object, "ID")
            guard !id.isEmpty else { return nil }
            let status = string(object, "Status")
            let labels = parseLabels(string(object, "Labels"))
            let names = string(object, "Names").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            return DockerContainer(
                id: id, names: names, image: string(object, "Image"),
                command: string(object, "Command"),
                state: DockerContainerState(raw: string(object, "State")), status: status,
                health: parseHealth(
                    status: status, healthStatus: string(object, "HealthStatus")),
                ports: parsePorts(string(object, "Ports")),
                composeProject: labels["com.docker.compose.project"],
                composeService: labels["com.docker.compose.service"],
                createdAt: string(object, "CreatedAt"))
        }
    }

    public static func applyStats(_ statsOutput: String, to containers: [DockerContainer])
        -> [DockerContainer]
    {
        var byID: [String: [String: Any]] = [:]
        for object in jsonLines(statsOutput) {
            let id =
                string(object, "ID").isEmpty
                ? string(object, "Container") : string(object, "ID")
            guard !id.isEmpty else { continue }
            byID[id] = object
        }
        return containers.map { container in
            var updated = container
            let stats =
                byID[container.id] ?? byID[container.shortID]
                ?? byID.first { container.id.hasPrefix($0.key) }?.value
            guard let stats else { return updated }
            updated.cpuPercent = parsePercent(string(stats, "CPUPerc"))
            let memory = parsePair(string(stats, "MemUsage"))
            updated.memUsedBytes = memory.0
            updated.memLimitBytes = memory.1
            let network = parsePair(string(stats, "NetIO"))
            updated.netRxBytes = network.0
            updated.netTxBytes = network.1
            return updated
        }
    }

    public static func images(_ output: String) -> [DockerImage] {
        jsonLines(output).compactMap { object in
            let id = string(object, "ID")
            guard !id.isEmpty else { return nil }
            let repository = string(object, "Repository")
            let tag = string(object, "Tag")
            return DockerImage(
                id: id, repository: repository, tag: tag,
                createdSince: string(object, "CreatedSince"),
                sizeBytes: parseSize(string(object, "Size")) ?? 0,
                dangling: repository == "<none>" || tag == "<none>")
        }
    }

    public static func volumes(_ output: String) -> [DockerVolume] {
        jsonLines(output).compactMap { object in
            let name = string(object, "Name")
            guard !name.isEmpty else { return nil }
            return DockerVolume(
                name: name, driver: string(object, "Driver"),
                mountpoint: string(object, "Mountpoint"))
        }
    }

    public static func networks(_ output: String) -> [DockerNetwork] {
        jsonLines(output).compactMap { object in
            let id = string(object, "ID")
            guard !id.isEmpty else { return nil }
            return DockerNetwork(
                id: id, name: string(object, "Name"), driver: string(object, "Driver"),
                scope: string(object, "Scope"))
        }
    }

    public static func diskUsage(_ output: String) -> [DockerDiskUsage] {
        jsonLines(output).compactMap { object in
            let type = string(object, "Type")
            guard !type.isEmpty else { return nil }
            let reclaimable =
                string(object, "Reclaimable")
                .split(separator: " ").first.map(String.init) ?? ""
            return DockerDiskUsage(
                type: type, totalCount: Int(string(object, "TotalCount")) ?? 0,
                active: Int(string(object, "Active")) ?? 0,
                sizeBytes: parseSize(string(object, "Size")) ?? 0,
                reclaimableBytes: parseSize(reclaimable) ?? 0)
        }
    }

    public static func volumeDetails(systemDFOutput: String) -> [String: (Int64?, Int?)] {
        guard let data = systemDFOutput.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let entries = object["Volumes"] as? [[String: Any]]
        else { return [:] }
        var result: [String: (Int64?, Int?)] = [:]
        for entry in entries {
            let name = string(entry, "Name")
            guard !name.isEmpty else { continue }
            let links = entry["Links"] as? Int ?? Int(string(entry, "Links"))
            result[name] = (parseSize(string(entry, "Size")), links)
        }
        return result
    }

    public static func splitLogLine(_ line: String, index: Int, isStderr: Bool) -> DockerLogLine {
        guard let space = line.firstIndex(of: " ") else {
            return DockerLogLine(id: index, timestamp: nil, text: line, isStderr: isStderr)
        }
        let candidate = String(line[..<space])
        guard candidate.count >= 20, candidate.contains("T"),
            candidate.hasSuffix("Z") || candidate.contains("+")
        else {
            return DockerLogLine(id: index, timestamp: nil, text: line, isStderr: isStderr)
        }
        return DockerLogLine(
            id: index, timestamp: candidate,
            text: String(line[line.index(after: space)...]), isStderr: isStderr)
    }

    public static func availability(versionOutput: String, versionStderr: String, status: Int32)
        -> DockerAvailability
    {
        if status == 0, let object = jsonLines(versionOutput).first {
            let server = object["Server"] as? [String: Any]
            let version = server.map { string($0, "Version") } ?? ""
            return DockerAvailability(
                status: .available(serverVersion: version, hasCompose: false))
        }
        let lowered = (versionStderr + versionOutput).lowercased()
        if lowered.contains("permission denied") {
            return DockerAvailability(status: .permissionDenied)
        }
        if lowered.contains("not found") || lowered.contains("command not found") {
            return DockerAvailability(status: .missing)
        }
        if lowered.contains("cannot connect to the docker daemon")
            || lowered.contains("is the docker daemon running")
        {
            return DockerAvailability(
                status: .daemonDown(message: "The Docker daemon is not running."))
        }
        if lowered.isEmpty { return DockerAvailability(status: .unknown) }
        return DockerAvailability(status: .missing)
    }
}
