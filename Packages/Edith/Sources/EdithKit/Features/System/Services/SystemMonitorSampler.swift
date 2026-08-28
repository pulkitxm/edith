import Darwin
import Foundation
import IOKit

public struct SystemMonitorThroughput: Equatable, Sendable {
    public var inboundBytesPerSecond: Double
    public var outboundBytesPerSecond: Double

    public init(inboundBytesPerSecond: Double = 0, outboundBytesPerSecond: Double = 0) {
        self.inboundBytesPerSecond = inboundBytesPerSecond
        self.outboundBytesPerSecond = outboundBytesPerSecond
    }
}

public struct SystemMonitorBattery: Equatable, Sendable {
    public var percent: Int
    public var isCharging: Bool
    public var externalPower: Bool
    public var watts: Double?

    public init(percent: Int, isCharging: Bool, externalPower: Bool, watts: Double? = nil) {
        self.percent = percent
        self.isCharging = isCharging
        self.externalPower = externalPower
        self.watts = watts
    }

    public var status: String {
        if isCharging { return "Charging" }
        return externalPower ? "Power Adapter" : "Battery"
    }
}

public struct SystemMonitorSnapshot: Equatable, Sendable {
    public var sampledAt: TimeInterval
    public var cpuPercent: Double
    public var memoryPercent: Double
    public var gpuPercent: Double?
    public var network: SystemMonitorThroughput
    public var disk: SystemMonitorThroughput
    public var rootDiskUsedPercent: Double?
    public var battery: SystemMonitorBattery?
    public var storageReadAt: TimeInterval?
    public var batteryReadAt: TimeInterval?

    public init(
        sampledAt: TimeInterval, cpuPercent: Double, memoryPercent: Double,
        gpuPercent: Double? = nil, network: SystemMonitorThroughput = .init(),
        disk: SystemMonitorThroughput = .init(), rootDiskUsedPercent: Double? = nil,
        battery: SystemMonitorBattery? = nil, storageReadAt: TimeInterval? = nil,
        batteryReadAt: TimeInterval? = nil
    ) {
        self.sampledAt = sampledAt
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.gpuPercent = gpuPercent
        self.network = network
        self.disk = disk
        self.rootDiskUsedPercent = rootDiskUsedPercent
        self.battery = battery
        self.storageReadAt = storageReadAt
        self.batteryReadAt = batteryReadAt
    }
}

enum SystemMonitorSamplingKind {
    case fast
    case gpu
    case slow
}

enum SystemMonitorSamplingPolicy {
    static let gpuInterval: TimeInterval = 10
    static let slowInterval: TimeInterval = 30

    static func shouldSample(
        _ kind: SystemMonitorSamplingKind, lastReadAt: TimeInterval?, at uptime: TimeInterval
    ) -> Bool {
        return switch kind {
        case .fast: true
        case .gpu: due(lastReadAt, at: uptime, interval: gpuInterval)
        case .slow: due(lastReadAt, at: uptime, interval: slowInterval)
        }
    }

    private static func due(
        _ lastReadAt: TimeInterval?, at uptime: TimeInterval, interval: TimeInterval
    ) -> Bool {
        guard let lastReadAt else { return true }
        return uptime < lastReadAt || uptime - lastReadAt >= interval
    }
}

public struct SustainedThresholdGate: Equatable, Sendable {
    private var heldSince: TimeInterval?
    private var lastReadAt: TimeInterval?
    private var delivered = false

    public init() {}

    public mutating func evaluate(
        value: Double?, threshold: Double, readAt: TimeInterval?, sustainedSeconds: TimeInterval,
        direction: Direction
    ) -> Bool {
        guard let value, let readAt, direction.matches(value, threshold: threshold) else {
            reset()
            return false
        }
        guard readAt != lastReadAt else { return false }
        lastReadAt = readAt
        guard !delivered else { return false }
        guard let heldSince else {
            self.heldSince = readAt
            return false
        }
        guard readAt - heldSince >= sustainedSeconds else { return false }
        delivered = true
        return true
    }

    public mutating func reset() {
        heldSince = nil
        lastReadAt = nil
        delivered = false
    }

    public enum Direction: Sendable {
        case atLeast
        case atMost

        fileprivate func matches(_ value: Double, threshold: Double) -> Bool {
            switch self {
            case .atLeast: value >= threshold
            case .atMost: value <= threshold
            }
        }
    }
}

public final class SystemMonitorSampler: @unchecked Sendable {
    private var previousCPU: CPUTicks?
    private var previousNetwork: (read: UInt64, written: UInt64, at: TimeInterval)?
    private var previousDisk: (read: UInt64, written: UInt64, at: TimeInterval)?
    private var gpuReadAt: TimeInterval?
    private var slowReadAt: TimeInterval?
    private var gpuPercent: Double?
    private var rootDiskUsedPercent: Double?
    private var battery: SystemMonitorBattery?
    private var storageReadAt: TimeInterval?
    private var batteryReadAt: TimeInterval?

    public init() {}

    public func sample(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime)
        -> SystemMonitorSnapshot
    {
        let currentCPU = SystemStatsReader.readCPUTicks()
        let cpuPercent: Double
        if let previousCPU, let currentCPU {
            cpuPercent = SystemStatsReader.cpuUsage(previous: previousCPU, current: currentCPU)
        } else {
            cpuPercent = 0
        }
        previousCPU = currentCPU

        let network = throughput(
            current: Self.readNetworkCounters(), previous: &previousNetwork, at: uptime)
        let disk = throughput(
            current: Self.readDiskCounters(), previous: &previousDisk, at: uptime)

        if SystemMonitorSamplingPolicy.shouldSample(.gpu, lastReadAt: gpuReadAt, at: uptime) {
            gpuPercent = Self.readGPUPercent()
            gpuReadAt = uptime
        }
        if SystemMonitorSamplingPolicy.shouldSample(.slow, lastReadAt: slowReadAt, at: uptime) {
            rootDiskUsedPercent = Self.readRootDiskUsedPercent()
            battery = Self.readBattery()
            storageReadAt = uptime
            batteryReadAt = battery == nil ? nil : uptime
            slowReadAt = uptime
        }

        return SystemMonitorSnapshot(
            sampledAt: uptime, cpuPercent: cpuPercent,
            memoryPercent: SystemStatsReader.memoryUsedPercent(), gpuPercent: gpuPercent,
            network: network, disk: disk, rootDiskUsedPercent: rootDiskUsedPercent,
            battery: battery, storageReadAt: storageReadAt, batteryReadAt: batteryReadAt)
    }

    public func reset() {
        previousCPU = nil
        previousNetwork = nil
        previousDisk = nil
        gpuReadAt = nil
        slowReadAt = nil
        gpuPercent = nil
        rootDiskUsedPercent = nil
        battery = nil
        storageReadAt = nil
        batteryReadAt = nil
    }

    static func bytesPerSecond(
        previous: UInt64, current: UInt64, elapsed: TimeInterval, maximumGap: TimeInterval = 30
    ) -> Double {
        guard elapsed > 0, elapsed <= maximumGap, current >= previous else { return 0 }
        return Double(current - previous) / elapsed
    }

    private func throughput(
        current: (read: UInt64, written: UInt64),
        previous: inout (read: UInt64, written: UInt64, at: TimeInterval)?, at uptime: TimeInterval
    ) -> SystemMonitorThroughput {
        defer { previous = (current.read, current.written, uptime) }
        guard let previous else { return SystemMonitorThroughput() }
        let elapsed = uptime - previous.at
        return SystemMonitorThroughput(
            inboundBytesPerSecond: Self.bytesPerSecond(
                previous: previous.read, current: current.read, elapsed: elapsed),
            outboundBytesPerSecond: Self.bytesPerSecond(
                previous: previous.written, current: current.written, elapsed: elapsed))
    }

    private static func readNetworkCounters() -> (read: UInt64, written: UInt64) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }
        var result = (read: UInt64(0), written: UInt64(0))
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                address.pointee.sa_family == UInt8(AF_LINK),
                let dataPointer = entry.pointee.ifa_data
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard includeNetworkInterface(name) else { continue }
            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            result.read += UInt64(data.ifi_ibytes)
            result.written += UInt64(data.ifi_obytes)
        }
        return result
    }

    private static func includeNetworkInterface(_ name: String) -> Bool {
        let excluded = ["lo", "utun", "awdl", "llw", "bridge", "ap", "gif", "stf", "anpi"]
        return !excluded.contains { name.hasPrefix($0) }
    }

    private static func readDiskCounters() -> (read: UInt64, written: UInt64) {
        var iterator = io_iterator_t()
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
                == kIOReturnSuccess
        else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var result = (read: UInt64(0), written: UInt64(0))
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let statistics = property("Statistics", from: service) as? [String: Any] {
                result.read += unsigned(statistics["Bytes (Read)"]) ?? 0
                result.written += unsigned(statistics["Bytes (Write)"]) ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }

    private static func readGPUPercent() -> Double? {
        var iterator = io_iterator_t()
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
                == kIOReturnSuccess
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard
                let statistics = property("PerformanceStatistics", from: service)
                    as? [String: Any], let value = unsigned(statistics["Device Utilization %"])
            else { continue }
            return min(100, Double(value))
        }
        return nil
    }

    private static func readRootDiskUsedPercent() -> Double? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
            let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        let available = max(
            0, min(Int64(total), values.volumeAvailableCapacityForImportantUsage ?? 0))
        return Double(Int64(total) - available) / Double(total) * 100
    }

    private static func readBattery() -> SystemMonitorBattery? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard
            IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
                == kIOReturnSuccess,
            let values = properties?.takeRetainedValue() as? [String: Any],
            let current = signed(values["CurrentCapacity"]),
            let maximum = signed(values["MaxCapacity"]), maximum > 0
        else { return nil }
        let voltage = signed(values["Voltage"])
        let amperage = signed(values["Amperage"]) ?? signed(values["InstantAmperage"])
        let watts: Double?
        if let voltage, let amperage, voltage > 0, amperage != 0 {
            watts = Double(voltage) / 1000 * Double(amperage) / 1000
        } else {
            watts = nil
        }
        return SystemMonitorBattery(
            percent: min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded()))),
            isCharging: (values["IsCharging"] as? Bool) ?? false,
            externalPower: (values["ExternalConnected"] as? Bool) ?? false, watts: watts)
    }

    private static func property(_ key: String, from entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        if let value = value as? NSNumber { return value.uint64Value }
        if let value = value as? String { return UInt64(value) }
        return nil
    }

    private static func signed(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }
}
