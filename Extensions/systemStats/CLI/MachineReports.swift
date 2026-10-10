import EdithExtensionCommands
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

}
