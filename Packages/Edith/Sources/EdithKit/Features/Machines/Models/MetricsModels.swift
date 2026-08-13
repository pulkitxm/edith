import Foundation

public struct MachineHello: Codable, Equatable, Sendable {
    public var os: String
    public var osID: String
    public var kernel: String
    public var arch: String
    public var host: String
    public var cpuModel: String
    public var cores: Int
    public var memTotalKB: Int64
    public var virtual: Bool

    public init(
        os: String, osID: String = "", kernel: String = "", arch: String = "",
        host: String = "", cpuModel: String = "", cores: Int = 0, memTotalKB: Int64 = 0,
        virtual: Bool = false
    ) {
        self.os = os
        self.osID = osID
        self.kernel = kernel
        self.arch = arch
        self.host = host
        self.cpuModel = cpuModel
        self.cores = cores
        self.memTotalKB = memTotalKB
        self.virtual = virtual
    }
}

public struct MachineCPU: Codable, Equatable, Sendable {
    public var total: Double
    public var steal: Double
    public var cores: [Double]

    public init(total: Double, steal: Double = 0, cores: [Double] = []) {
        self.total = total
        self.steal = steal
        self.cores = cores
    }
}

public struct MachineMemory: Codable, Equatable, Sendable {
    public var totalKB: Int64
    public var availKB: Int64
    public var usedKB: Int64
    public var buffcacheKB: Int64
    public var swapTotalKB: Int64
    public var swapUsedKB: Int64

    public init(
        totalKB: Int64, availKB: Int64, usedKB: Int64, buffcacheKB: Int64 = 0,
        swapTotalKB: Int64 = 0, swapUsedKB: Int64 = 0
    ) {
        self.totalKB = totalKB
        self.availKB = availKB
        self.usedKB = usedKB
        self.buffcacheKB = buffcacheKB
        self.swapTotalKB = swapTotalKB
        self.swapUsedKB = swapUsedKB
    }

    public var usedPercent: Double {
        totalKB > 0 ? Double(usedKB) / Double(totalKB) * 100 : 0
    }
}

public struct MachineTasks: Codable, Equatable, Sendable {
    public var runnable: Int
    public var total: Int

    public init(runnable: Int = 0, total: Int = 0) {
        self.runnable = runnable
        self.total = total
    }
}

public struct MachineDiskDevice: Codable, Equatable, Sendable {
    public var n: String
    public var readBps: Double
    public var writeBps: Double
    public var busy: Double

    public init(n: String, readBps: Double, writeBps: Double, busy: Double) {
        self.n = n
        self.readBps = readBps
        self.writeBps = writeBps
        self.busy = busy
    }
}

public struct MachineDiskIO: Codable, Equatable, Sendable {
    public var devices: [MachineDiskDevice]
    public var readBps: Double
    public var writeBps: Double

    public init(devices: [MachineDiskDevice] = [], readBps: Double = 0, writeBps: Double = 0) {
        self.devices = devices
        self.readBps = readBps
        self.writeBps = writeBps
    }
}

public struct MachineNetInterface: Codable, Equatable, Sendable {
    public var n: String
    public var rxBps: Double
    public var txBps: Double
    public var virtual: Bool

    public init(n: String, rxBps: Double, txBps: Double, virtual: Bool = false) {
        self.n = n
        self.rxBps = rxBps
        self.txBps = txBps
        self.virtual = virtual
    }
}

public struct MachineNetwork: Codable, Equatable, Sendable {
    public var ifaces: [MachineNetInterface]
    public var rxBps: Double
    public var txBps: Double

    public init(ifaces: [MachineNetInterface] = [], rxBps: Double = 0, txBps: Double = 0) {
        self.ifaces = ifaces
        self.rxBps = rxBps
        self.txBps = txBps
    }
}

public struct MachineProcess: Codable, Equatable, Identifiable, Sendable {
    public var pid: Int
    public var user: String
    public var cpu: Double
    public var mem: Double
    public var rssKB: Int64
    public var name: String
    public var cmd: String

    public var id: Int { pid }

    public init(
        pid: Int, user: String, cpu: Double, mem: Double, rssKB: Int64, name: String,
        cmd: String
    ) {
        self.pid = pid
        self.user = user
        self.cpu = cpu
        self.mem = mem
        self.rssKB = rssKB
        self.name = name
        self.cmd = cmd
    }
}

public struct MachineSample: Codable, Equatable, Sendable {
    public var ts: Double
    public var dt: Double
    public var cpu: MachineCPU
    public var mem: MachineMemory
    public var load: [Double]
    public var tasks: MachineTasks
    public var uptime: Double
    public var disk: MachineDiskIO
    public var net: MachineNetwork
    public var procs: [MachineProcess]

    public init(
        ts: Double, dt: Double, cpu: MachineCPU, mem: MachineMemory, load: [Double] = [],
        tasks: MachineTasks = MachineTasks(), uptime: Double = 0,
        disk: MachineDiskIO = MachineDiskIO(), net: MachineNetwork = MachineNetwork(),
        procs: [MachineProcess] = []
    ) {
        self.ts = ts
        self.dt = dt
        self.cpu = cpu
        self.mem = mem
        self.load = load
        self.tasks = tasks
        self.uptime = uptime
        self.disk = disk
        self.net = net
        self.procs = procs
    }
}

public struct MachineFilesystem: Codable, Equatable, Identifiable, Sendable {
    public var fs: String
    public var mount: String
    public var totalKB: Int64
    public var usedKB: Int64
    public var availKB: Int64

    public var id: String { mount }

    public init(fs: String, mount: String, totalKB: Int64, usedKB: Int64, availKB: Int64) {
        self.fs = fs
        self.mount = mount
        self.totalKB = totalKB
        self.usedKB = usedKB
        self.availKB = availKB
    }

    public var usedPercent: Double {
        totalKB > 0 ? Double(usedKB) / Double(totalKB) * 100 : 0
    }
}

public struct MachineTemperature: Codable, Equatable, Sendable {
    public var label: String
    public var c: Double

    public init(label: String, c: Double) {
        self.label = label
        self.c = c
    }
}

public struct MachineFan: Codable, Equatable, Identifiable, Sendable {
    public var label: String
    public var rpm: Int

    public var id: String { label }

    public init(label: String, rpm: Int) {
        self.label = label
        self.rpm = rpm
    }
}

public struct MachinePlatformProfile: Codable, Equatable, Sendable {
    public var current: String
    public var choices: [String]

    public init(current: String, choices: [String]) {
        self.current = current
        self.choices = choices
    }
}

public struct MachineBattery: Codable, Equatable, Sendable {
    public var percent: Int
    public var status: String

    public init(percent: Int, status: String) {
        self.percent = percent
        self.status = status
    }
}

public struct MachineGPU: Codable, Equatable, Sendable {
    public var name: String
    public var util: Int
    public var memUsedMB: Int
    public var memTotalMB: Int
    public var temp: Int

    public init(name: String, util: Int, memUsedMB: Int, memTotalMB: Int, temp: Int) {
        self.name = name
        self.util = util
        self.memUsedMB = memUsedMB
        self.memTotalMB = memTotalMB
        self.temp = temp
    }
}

public struct MachineSlow: Codable, Equatable, Sendable {
    public var disks: [MachineFilesystem]
    public var temps: [MachineTemperature]
    public var fans: [MachineFan]
    public var platformProfile: MachinePlatformProfile?
    public var battery: MachineBattery?
    public var gpu: MachineGPU?

    public init(
        disks: [MachineFilesystem] = [], temps: [MachineTemperature] = [],
        fans: [MachineFan] = [], platformProfile: MachinePlatformProfile? = nil,
        battery: MachineBattery? = nil, gpu: MachineGPU? = nil
    ) {
        self.disks = disks
        self.temps = temps
        self.fans = fans
        self.platformProfile = platformProfile
        self.battery = battery
        self.gpu = gpu
    }
}

public enum MachineMetricRecord: Equatable, Sendable {
    case hello(MachineHello)
    case sample(MachineSample)
    case slow(MachineSlow)
}

public enum MachineMetricsDecoder {
    public static let sentinel = "@EDITH@"

    public static func decode(line: String) -> MachineMetricRecord? {
        guard line.hasPrefix(sentinel) else { return nil }
        let json = line.dropFirst(sentinel.count)
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        guard let kind = try? decoder.decode(RecordKind.self, from: data) else { return nil }
        switch kind.t {
        case "hello":
            return (try? decoder.decode(MachineHello.self, from: data)).map { .hello($0) }
        case "sample":
            return (try? decoder.decode(MachineSample.self, from: data)).map { .sample($0) }
        case "slow":
            return (try? decoder.decode(MachineSlow.self, from: data)).map { .slow($0) }
        default:
            return nil
        }
    }

    private struct RecordKind: Codable {
        let t: String
    }
}
