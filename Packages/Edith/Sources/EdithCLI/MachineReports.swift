import EdithKit
import Foundation

public enum MachineReports {
    public static func hello(_ value: MachineHello) -> JSONValue {
        .object([
            "os": .string(value.os),
            "osID": .string(value.osID),
            "kernel": .string(value.kernel),
            "arch": .string(value.arch),
            "host": .string(value.host),
            "cpuModel": .string(value.cpuModel),
            "cores": .int(value.cores),
            "memTotalKB": .number(value.memTotalKB),
            "virtual": .bool(value.virtual),
        ])
    }

    public static func sample(_ value: MachineSample, processes: Int = 0) -> JSONValue {
        .object([
            "at": .date(Date(timeIntervalSince1970: value.ts)),
            "intervalSeconds": .double(value.dt),
            "cpu": .object([
                "totalPercent": .double(value.cpu.total),
                "stealPercent": .double(value.cpu.steal),
                "corePercent": .doubles(value.cpu.cores),
            ]),
            "memory": .object([
                "totalKB": .number(value.mem.totalKB),
                "usedKB": .number(value.mem.usedKB),
                "availableKB": .number(value.mem.availKB),
                "buffCacheKB": .number(value.mem.buffcacheKB),
                "swapTotalKB": .number(value.mem.swapTotalKB),
                "swapUsedKB": .number(value.mem.swapUsedKB),
                "usedPercent": .double(value.mem.usedPercent),
            ]),
            "load": .doubles(value.load),
            "tasks": .object([
                "runnable": .int(value.tasks.runnable),
                "total": .int(value.tasks.total),
            ]),
            "uptimeSeconds": .double(value.uptime),
            "disk": .object([
                "readBps": .double(value.disk.readBps),
                "writeBps": .double(value.disk.writeBps),
                "devices": .array(
                    value.disk.devices.map { device in
                        .object([
                            "name": .string(device.n),
                            "readBps": .double(device.readBps),
                            "writeBps": .double(device.writeBps),
                            "busyPercent": .double(device.busy),
                        ])
                    }),
            ]),
            "network": .object([
                "rxBps": .double(value.net.rxBps),
                "txBps": .double(value.net.txBps),
                "interfaces": .array(
                    value.net.ifaces.map { iface in
                        .object([
                            "name": .string(iface.n),
                            "rxBps": .double(iface.rxBps),
                            "txBps": .double(iface.txBps),
                            "virtual": .bool(iface.virtual),
                        ])
                    }),
            ]),
            "processes": .array(
                value.procs.prefix(processes).map { process in
                    .object([
                        "pid": .int(process.pid),
                        "user": .string(process.user),
                        "cpuPercent": .double(process.cpu),
                        "memPercent": .double(process.mem),
                        "rssKB": .number(process.rssKB),
                        "name": .string(process.name),
                        "command": .string(process.cmd),
                    ])
                }),
        ])
    }

    public static func slow(_ value: MachineSlow) -> JSONValue {
        .object([
            "filesystems": .array(
                value.disks.map { disk in
                    .object([
                        "filesystem": .string(disk.fs),
                        "mount": .string(disk.mount),
                        "totalKB": .number(disk.totalKB),
                        "usedKB": .number(disk.usedKB),
                        "availableKB": .number(disk.availKB),
                        "usedPercent": .double(disk.usedPercent),
                    ])
                }),
            "temperatures": .array(
                value.temps.map { temp in
                    .object(["label": .string(temp.label), "celsius": .double(temp.c)])
                }),
            "fans": .array(
                value.fans.map { fan in
                    .object(["label": .string(fan.label), "rpm": .int(fan.rpm)])
                }),
            "platformProfile": value.platformProfile.map { profile in
                JSONValue.object([
                    "current": .string(profile.current),
                    "choices": .strings(profile.choices),
                ])
            } ?? .null,
            "battery": value.battery.map { battery in
                JSONValue.object([
                    "percent": .int(battery.percent), "status": .string(battery.status),
                ])
            } ?? .null,
            "gpu": value.gpu.map { gpu in
                JSONValue.object([
                    "name": .string(gpu.name),
                    "utilPercent": .int(gpu.util),
                    "memUsedMB": .int(gpu.memUsedMB),
                    "memTotalMB": .int(gpu.memTotalMB),
                    "temperature": .int(gpu.temp),
                ])
            } ?? .null,
        ])
    }

    public static func container(_ value: DockerContainer) -> JSONValue {
        .object([
            "id": .string(value.id),
            "shortID": .string(value.shortID),
            "name": .string(value.displayName),
            "names": .strings(value.names),
            "image": .string(value.image),
            "command": .string(value.command),
            "state": .string(value.state.rawValue),
            "status": .string(value.status),
            "health": .string(value.health.rawValue),
            "ports": .strings(value.ports.map(\.displayName)),
            "composeProject": .optional(value.composeProject),
            "composeService": .optional(value.composeService),
            "createdAt": .string(value.createdAt),
            "cpuPercent": .optional(value.cpuPercent),
            "memUsedBytes": .optional(value.memUsedBytes.map { Int($0) }),
            "memLimitBytes": .optional(value.memLimitBytes.map { Int($0) }),
        ])
    }

    public static func image(_ value: DockerImage) -> JSONValue {
        .object([
            "id": .string(value.id),
            "shortID": .string(value.shortID),
            "repository": .string(value.repository),
            "tag": .string(value.tag),
            "createdSince": .string(value.createdSince),
            "sizeBytes": .number(value.sizeBytes),
            "dangling": .bool(value.dangling),
        ])
    }

    public static func volume(_ value: DockerVolume) -> JSONValue {
        .object([
            "name": .string(value.name),
            "driver": .string(value.driver),
            "mountpoint": .string(value.mountpoint),
            "sizeBytes": .optional(value.sizeBytes.map { Int($0) }),
            "containers": .optional(value.containerCount),
            "inUse": .bool(value.inUse),
        ])
    }

    public static func network(_ value: DockerNetwork) -> JSONValue {
        .object([
            "id": .string(value.id),
            "name": .string(value.name),
            "driver": .string(value.driver),
            "scope": .string(value.scope),
        ])
    }

    public static func file(_ value: RemoteFileEntry) -> JSONValue {
        .object([
            "name": .string(value.name),
            "path": .string(value.path),
            "kind": .string(value.kind.rawValue),
            "sizeBytes": .number(value.sizeBytes),
            "modified": .date(value.modified),
            "mode": .string(value.mode),
            "linkTarget": .optional(value.linkTarget),
        ])
    }

    public static func service(_ value: SystemdService) -> JSONValue {
        .object([
            "unit": .string(value.unit),
            "load": .string(value.load),
            "active": .string(value.active),
            "sub": .string(value.sub),
            "description": .string(value.describes),
            "running": .bool(value.isRunning),
            "failed": .bool(value.isFailed),
        ])
    }

    public static func availability(_ value: DockerAvailability) -> JSONValue {
        switch value.status {
        case .unknown:
            return .object(["state": .string("unknown")])
        case let .available(serverVersion, hasCompose):
            return .object([
                "state": .string("available"),
                "serverVersion": .string(serverVersion),
                "compose": .bool(hasCompose),
            ])
        case .missing:
            return .object(["state": .string("missing")])
        case .permissionDenied:
            return .object(["state": .string("permissionDenied")])
        case let .daemonDown(message):
            return .object(["state": .string("daemonDown"), "message": .string(message)])
        }
    }
}
