import Foundation

public struct MachineSnapshot: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isLocal: Bool
    public var online: Bool
    public var cores: Int
    public var cpuPercent: Double
    public var memoryTotalKB: Int64
    public var memoryUsedKB: Int64
    public var swapTotalKB: Int64
    public var swapUsedKB: Int64
    public var diskTotalKB: Int64
    public var diskUsedKB: Int64
    public var loadOne: Double
    public var uptime: Double
    public var containersRunning: Int
    public var containersTotal: Int
    public var updatesAvailable: Int?
    public var hottestTemperature: Double?
    public var os: String

    public init(
        id: UUID, name: String, isLocal: Bool, online: Bool, cores: Int, cpuPercent: Double,
        memoryTotalKB: Int64, memoryUsedKB: Int64, swapTotalKB: Int64 = 0,
        swapUsedKB: Int64 = 0, diskTotalKB: Int64 = 0, diskUsedKB: Int64 = 0,
        loadOne: Double = 0, uptime: Double = 0, containersRunning: Int = 0,
        containersTotal: Int = 0, updatesAvailable: Int? = nil,
        hottestTemperature: Double? = nil, os: String = ""
    ) {
        self.id = id
        self.name = name
        self.isLocal = isLocal
        self.online = online
        self.cores = cores
        self.cpuPercent = cpuPercent
        self.memoryTotalKB = memoryTotalKB
        self.memoryUsedKB = memoryUsedKB
        self.swapTotalKB = swapTotalKB
        self.swapUsedKB = swapUsedKB
        self.diskTotalKB = diskTotalKB
        self.diskUsedKB = diskUsedKB
        self.loadOne = loadOne
        self.uptime = uptime
        self.containersRunning = containersRunning
        self.containersTotal = containersTotal
        self.updatesAvailable = updatesAvailable
        self.hottestTemperature = hottestTemperature
        self.os = os
    }

    public var memoryPercent: Double {
        memoryTotalKB > 0 ? Double(memoryUsedKB) / Double(memoryTotalKB) * 100 : 0
    }

    public var diskPercent: Double {
        diskTotalKB > 0 ? Double(diskUsedKB) / Double(diskTotalKB) * 100 : 0
    }

    public var loadPerCore: Double {
        cores > 0 ? loadOne / Double(cores) : 0
    }
}

public struct FleetAlert: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case offline
        case diskFull
        case memoryPressure
        case highLoad
        case updates
        case hot
    }

    public var machineName: String
    public var kind: Kind
    public var detail: String

    public var id: String { "\(machineName).\(kind.rawValue)" }

    public init(machineName: String, kind: Kind, detail: String) {
        self.machineName = machineName
        self.kind = kind
        self.detail = detail
    }

    public var symbol: String {
        switch kind {
        case .offline: return "bolt.horizontal.circle"
        case .diskFull: return "externaldrive.badge.exclamationmark"
        case .memoryPressure: return "memorychip"
        case .highLoad: return "gauge.with.dots.needle.100percent"
        case .updates: return "shippingbox.and.arrow.backward"
        case .hot: return "thermometer.high"
        }
    }
}

public struct FleetSummary: Equatable, Sendable {
    public var machinesOnline: Int
    public var machinesTotal: Int
    public var totalCores: Int
    public var cpuPercent: Double
    public var memoryTotalKB: Int64
    public var memoryUsedKB: Int64
    public var swapTotalKB: Int64
    public var swapUsedKB: Int64
    public var diskTotalKB: Int64
    public var diskUsedKB: Int64
    public var containersRunning: Int
    public var containersTotal: Int
    public var alerts: [FleetAlert]

    public var memoryPercent: Double {
        memoryTotalKB > 0 ? Double(memoryUsedKB) / Double(memoryTotalKB) * 100 : 0
    }

    public var diskPercent: Double {
        diskTotalKB > 0 ? Double(diskUsedKB) / Double(diskTotalKB) * 100 : 0
    }

    public var swapPercent: Double {
        swapTotalKB > 0 ? Double(swapUsedKB) / Double(swapTotalKB) * 100 : 0
    }
}

public enum FleetMath {
    public static let diskWarningPercent = 90.0
    public static let memoryWarningPercent = 92.0
    public static let loadWarningPerCore = 1.5
    public static let temperatureWarning = 85.0

    public static func summarize(_ snapshots: [MachineSnapshot]) -> FleetSummary {
        let online = snapshots.filter(\.online)
        let totalCores = online.reduce(0) { $0 + $1.cores }
        let weightedCPU = online.reduce(0.0) { $0 + $1.cpuPercent * Double($1.cores) }
        return FleetSummary(
            machinesOnline: online.count,
            machinesTotal: snapshots.count,
            totalCores: totalCores,
            cpuPercent: totalCores > 0 ? weightedCPU / Double(totalCores) : 0,
            memoryTotalKB: online.reduce(0) { $0 + $1.memoryTotalKB },
            memoryUsedKB: online.reduce(0) { $0 + $1.memoryUsedKB },
            swapTotalKB: online.reduce(0) { $0 + $1.swapTotalKB },
            swapUsedKB: online.reduce(0) { $0 + $1.swapUsedKB },
            diskTotalKB: online.reduce(0) { $0 + $1.diskTotalKB },
            diskUsedKB: online.reduce(0) { $0 + $1.diskUsedKB },
            containersRunning: online.reduce(0) { $0 + $1.containersRunning },
            containersTotal: online.reduce(0) { $0 + $1.containersTotal },
            alerts: alerts(for: snapshots))
    }

    public static func alerts(for snapshots: [MachineSnapshot]) -> [FleetAlert] {
        var alerts: [FleetAlert] = []
        for snapshot in snapshots {
            guard snapshot.online else {
                alerts.append(
                    FleetAlert(
                        machineName: snapshot.name, kind: .offline, detail: "Not reachable"))
                continue
            }
            if snapshot.diskPercent >= diskWarningPercent {
                alerts.append(
                    FleetAlert(
                        machineName: snapshot.name, kind: .diskFull,
                        detail: String(format: "Disk %.0f%% full", snapshot.diskPercent)))
            }
            if snapshot.memoryPercent >= memoryWarningPercent {
                alerts.append(
                    FleetAlert(
                        machineName: snapshot.name, kind: .memoryPressure,
                        detail: String(format: "Memory %.0f%% used", snapshot.memoryPercent)))
            }
            if snapshot.loadPerCore >= loadWarningPerCore {
                alerts.append(
                    FleetAlert(
                        machineName: snapshot.name, kind: .highLoad,
                        detail: String(format: "Load %.2f per core", snapshot.loadPerCore)))
            }
            if let temperature = snapshot.hottestTemperature, temperature >= temperatureWarning {
                alerts.append(
                    FleetAlert(
                        machineName: snapshot.name, kind: .hot,
                        detail: String(format: "%.0f°C", temperature)))
            }
            if let updates = snapshot.updatesAvailable, updates > 0 {
                alerts.append(
                    FleetAlert(
                        machineName: snapshot.name, kind: .updates,
                        detail: "\(updates) update\(updates == 1 ? "" : "s") available"))
            }
        }
        return alerts
    }

    public static func busiest(_ snapshots: [MachineSnapshot]) -> MachineSnapshot? {
        snapshots.filter(\.online).max {
            pressure(of: $0) < pressure(of: $1)
        }
    }

    public static func pressure(of snapshot: MachineSnapshot) -> Double {
        max(snapshot.cpuPercent, snapshot.memoryPercent, snapshot.diskPercent)
    }

    public static func sortedByPressure(_ snapshots: [MachineSnapshot]) -> [MachineSnapshot] {
        snapshots.sorted { lhs, rhs in
            if lhs.online != rhs.online { return lhs.online }
            return pressure(of: lhs) > pressure(of: rhs)
        }
    }
}
