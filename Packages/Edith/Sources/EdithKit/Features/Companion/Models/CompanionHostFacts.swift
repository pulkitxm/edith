import Foundation

public enum CompanionRuntimeKind: String, CaseIterable, Codable, Hashable, Sendable {
    case docker
    case appleContainer
    case podman
    case colima

    public var executable: String {
        switch self {
        case .docker: "docker"
        case .appleContainer: "container"
        case .podman: "podman"
        case .colima: "colima"
        }
    }

    public var displayName: String {
        switch self {
        case .docker: "Docker"
        case .appleContainer: "Apple Container"
        case .podman: "Podman"
        case .colima: "Colima"
        }
    }

    public var runsCompose: Bool {
        switch self {
        case .docker, .podman, .colima: true
        case .appleContainer: false
        }
    }
}

public struct CompanionRuntimeStatus: Codable, Equatable, Sendable {
    public let kind: CompanionRuntimeKind
    public let version: String?
    public let daemonRunning: Bool
    public let composeVersion: String?

    public init(
        kind: CompanionRuntimeKind, version: String?, daemonRunning: Bool,
        composeVersion: String? = nil
    ) {
        self.kind = kind
        self.version = version
        self.daemonRunning = daemonRunning
        self.composeVersion = composeVersion
    }

    public var installed: Bool { version != nil }

    public var canRunTheStack: Bool {
        installed && daemonRunning && kind.runsCompose && composeVersion != nil
    }
}

public struct CompanionHostFacts: Codable, Equatable, Sendable {
    public let os: String
    public let arch: String
    public let cpuCores: Int
    public let memoryMb: Int
    public let diskFreeMb: Int
    public let gpuModel: String?
    public let runtimes: [CompanionRuntimeStatus]
    public let portsTaken: [Int]

    public init(
        os: String, arch: String, cpuCores: Int, memoryMb: Int, diskFreeMb: Int,
        gpuModel: String?, runtimes: [CompanionRuntimeStatus], portsTaken: [Int]
    ) {
        self.os = os
        self.arch = arch
        self.cpuCores = cpuCores
        self.memoryMb = memoryMb
        self.diskFreeMb = diskFreeMb
        self.gpuModel = gpuModel
        self.runtimes = runtimes
        self.portsTaken = portsTaken
    }

    public static let requiredDiskMb = 12_000
    public static let requiredPorts = [4820, 5432, 6379, 11434]

    public static func requiredPorts(for config: CompanionStackConfig) -> [Int] {
        [config.apiPort, config.pgPort, config.redisPort, 11434]
    }

    public func runtime(_ kind: CompanionRuntimeKind) -> CompanionRuntimeStatus? {
        runtimes.first { $0.kind == kind }
    }

    public var usableRuntime: CompanionRuntimeStatus? {
        runtimes.first { $0.canRunTheStack }
    }

    public var installedRuntimes: [CompanionRuntimeStatus] {
        runtimes.filter(\.installed)
    }

    public var blockers: [CompanionBlocker] {
        blockers(ports: Self.requiredPorts)
    }

    public func blockers(ports: [Int]) -> [CompanionBlocker] {
        var found: [CompanionBlocker] = []
        if usableRuntime == nil {
            let stopped = installedRuntimes.first { !$0.daemonRunning }
            if let stopped {
                found.append(.runtimeStopped(stopped.kind))
            } else {
                found.append(.noRuntime)
            }
        }
        if diskFreeMb < Self.requiredDiskMb {
            found.append(.notEnoughDisk(freeMb: diskFreeMb, needMb: Self.requiredDiskMb))
        }
        let clashes = ports.filter { portsTaken.contains($0) }
        if !clashes.isEmpty { found.append(.portsInUse(clashes)) }
        return found
    }

    public var plainEnglish: String {
        var parts = ["\(os) \(arch)", "\(cpuCores) cores", "\(memoryMb / 1024) GB"]
        if let gpuModel, !gpuModel.isEmpty { parts.append(gpuModel) }
        if let usableRuntime {
            parts.append("\(usableRuntime.kind.displayName) \(usableRuntime.version ?? "")")
        } else if let installed = installedRuntimes.first {
            parts.append("\(installed.kind.displayName) installed, not running")
        } else {
            parts.append("no container runtime")
        }
        return parts.joined(separator: " · ")
    }
}

public enum CompanionBlocker: Equatable, Sendable {
    case noRuntime
    case runtimeStopped(CompanionRuntimeKind)
    case notEnoughDisk(freeMb: Int, needMb: Int)
    case portsInUse([Int])
    case unreachable(String)

    public var headline: String {
        switch self {
        case .noRuntime:
            "No container runtime"
        case let .runtimeStopped(kind):
            "\(kind.displayName) is installed but not running"
        case let .notEnoughDisk(freeMb, needMb):
            "Needs \(needMb / 1000) GB free, has \(freeMb / 1000) GB"
        case let .portsInUse(ports):
            ports.count == 1
                ? "Port \(ports[0]) is already in use"
                : "Ports \(ports.map(String.init).joined(separator: ", ")) are already in use"
        case let .unreachable(detail):
            detail
        }
    }

    public var fix: String {
        switch self {
        case .noRuntime: "Install one"
        case let .runtimeStopped(kind): "Start \(kind.displayName)"
        case .notEnoughDisk: "Free up space"
        case .portsInUse: "Choose other ports"
        case .unreachable: "Reconnect"
        }
    }
}

public enum CompanionHostProbe {
    public static let script = script(ports: CompanionHostFacts.requiredPorts)

    public static func script(ports: [Int]) -> String {
        let list = ports.map(String.init).joined(separator: " ")
        return template.replacingOccurrences(of: "4820 5432 6379 11434", with: list)
    }

    static let template = """
        os=darwin
        arch=$(uname -m)
        cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 0)
        rammb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
        diskmb=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}')
        gpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
        [ -n "$diskmb" ] || diskmb=0
        emit_runtime() {
          name=$1; bin=$2
          if command -v "$bin" >/dev/null 2>&1; then
            case "$bin" in
              docker) ver=$(docker version --format '{{.Client.Version}}' 2>/dev/null) ;;
              container) ver=$(container --version 2>/dev/null | sed -n 's/.*version \\([0-9][0-9.]*\\).*/\\1/p') ;;
              podman) ver=$(podman --version 2>/dev/null | sed -n 's/.*version \\([0-9][0-9.]*\\).*/\\1/p') ;;
              colima) ver=$(colima version 2>/dev/null | sed -n 's/.*version \\([0-9][0-9.]*\\).*/\\1/p' | head -1) ;;
            esac
            [ -n "$ver" ] || ver=unknown
            running=false
            case "$bin" in
              docker) docker info >/dev/null 2>&1 && running=true ;;
              container) container system status >/dev/null 2>&1 && running=true ;;
              podman) podman info >/dev/null 2>&1 && running=true ;;
              colima) colima status >/dev/null 2>&1 && running=true ;;
            esac
            compose=
            case "$bin" in
              docker) compose=$(docker compose version --short 2>/dev/null) ;;
              podman) compose=$(podman compose version --short 2>/dev/null) ;;
              colima) compose=$(docker compose version --short 2>/dev/null) ;;
            esac
            printf 'runtime %s %s %s %s\\n' "$name" "$ver" "$running" "${compose:-none}"
          fi
        }
        emit_runtime docker docker
        emit_runtime appleContainer container
        emit_runtime podman podman
        emit_runtime colima colima
        taken=
        for p in 4820 5432 6379 11434; do
          if command -v ss >/dev/null 2>&1; then
            ss -ltn 2>/dev/null | grep -q ":$p " && taken="$taken $p"
          elif command -v lsof >/dev/null 2>&1; then
            lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && taken="$taken $p"
          fi
        done
        printf 'os %s\\n' "$os"
        printf 'arch %s\\n' "$arch"
        printf 'cores %s\\n' "$cores"
        printf 'rammb %s\\n' "$rammb"
        printf 'diskmb %s\\n' "$diskmb"
        printf 'gpu %s\\n' "$gpu"
        printf 'ports%s\\n' "$taken"
        """

    public static func parse(_ output: String) -> CompanionHostFacts {
        var values: [String: String] = [:]
        var runtimes: [CompanionRuntimeStatus] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let key = parts.first else { continue }
            if key == "runtime" {
                guard parts.count >= 5, let kind = CompanionRuntimeKind(rawValue: parts[1]) else {
                    continue
                }
                runtimes.append(
                    CompanionRuntimeStatus(
                        kind: kind,
                        version: parts[2] == "unknown" ? nil : parts[2],
                        daemonRunning: parts[3] == "true",
                        composeVersion: parts[4] == "none" ? nil : parts[4]))
            } else {
                values[key] = parts.dropFirst().joined(separator: " ")
            }
        }
        let ports = (values["ports"] ?? "")
            .split(separator: " ", omittingEmptySubsequences: true)
            .compactMap { Int($0) }
        let gpu = values["gpu"]?.trimmingCharacters(in: .whitespaces)
        return CompanionHostFacts(
            os: values["os"] ?? "unknown",
            arch: values["arch"] ?? "unknown",
            cpuCores: Int(values["cores"] ?? "") ?? 0,
            memoryMb: Int(values["rammb"] ?? "") ?? 0,
            diskFreeMb: Int(values["diskmb"] ?? "") ?? 0,
            gpuModel: (gpu?.isEmpty ?? true) ? nil : gpu,
            runtimes: runtimes,
            portsTaken: ports)
    }
}
