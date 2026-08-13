import Darwin
import Foundation

public final class LocalMachineSampler: @unchecked Sendable {
    private var prevCores: [(used: Double, total: Double)] = []
    private var prevAggregate: CPUTicks?
    private var prevNet: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var prevSampleAt: Date?
    private var processSampleIndex = 0
    private var cachedProcesses: [MachineProcess] = []
    private let processSampleStride: Int
    private let processReader: @Sendable () async -> [MachineProcess]

    public init() {
        processSampleStride = MachineResourcePolicy.localProcessSampleStride
        processReader = { await Self.readProcesses() }
    }

    init(
        processSampleStride: Int,
        processReader: @escaping @Sendable () async -> [MachineProcess]
    ) {
        self.processSampleStride = max(1, processSampleStride)
        self.processReader = processReader
    }

    public func hello() -> MachineHello {
        MachineHello(
            os: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            osID: "macos",
            kernel: sysctlString("kern.osrelease"),
            arch: sysctlString("hw.machine"),
            host: Host.current().localizedName ?? sysctlString("kern.hostname"),
            cpuModel: sysctlString("machdep.cpu.brand_string"),
            cores: ProcessInfo.processInfo.activeProcessorCount,
            memTotalKB: Int64(ProcessInfo.processInfo.physicalMemory / 1024),
            virtual: false)
    }

    public func sample() async -> MachineSample {
        let now = Date()
        let dt = prevSampleAt.map { now.timeIntervalSince($0) } ?? 0
        prevSampleAt = now

        let cores = coreLoads()
        let aggregate = SystemStatsReader.readCPUTicks()
        var totalPercent = 0.0
        if let previous = prevAggregate, let current = aggregate {
            totalPercent = SystemStatsReader.cpuUsage(previous: previous, current: current)
        }
        prevAggregate = aggregate

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)

        if MachineResourcePolicy.shouldRefreshProcesses(
            sampleIndex: processSampleIndex, stride: processSampleStride)
        {
            cachedProcesses = await processReader()
        }
        processSampleIndex += 1
        let processes = cachedProcesses
        return MachineSample(
            ts: now.timeIntervalSince1970, dt: dt,
            cpu: MachineCPU(total: totalPercent, cores: cores),
            mem: memory(),
            load: loads,
            tasks: MachineTasks(runnable: 0, total: processes.count),
            uptime: ProcessInfo.processInfo.systemUptime,
            disk: MachineDiskIO(),
            net: network(dt: dt),
            procs: Array(processes.prefix(30)))
    }

    public func slow() -> MachineSlow {
        var disks: [MachineFilesystem] = []
        let keys: [URLResourceKey] = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeNameKey, .volumeIsBrowsableKey,
        ]
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.volumeIsBrowsable == true,
                let total = values.volumeTotalCapacity, total > 0
            else { continue }
            let available = values.volumeAvailableCapacityForImportantUsage ?? 0
            let totalKB = Int64(total) / 1024
            let availKB = available / 1024
            disks.append(
                MachineFilesystem(
                    fs: values.volumeName ?? url.lastPathComponent, mount: url.path,
                    totalKB: totalKB, usedKB: max(0, totalKB - availKB), availKB: availKB))
        }
        return MachineSlow(disks: disks, temps: [], battery: Self.battery(), gpu: nil)
    }

    private func memory() -> MachineMemory {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let totalKB = Int64(ProcessInfo.processInfo.physicalMemory / 1024)
        guard result == KERN_SUCCESS else {
            return MachineMemory(totalKB: totalKB, availKB: 0, usedKB: 0)
        }
        let pageSize = UInt64(vm_page_size)
        let usedKB = Int64(
            SystemStatsReader.memoryUsedBytes(
                anonymousPages: UInt64(stats.internal_page_count),
                wiredPages: UInt64(stats.wire_count),
                compressedPages: UInt64(stats.compressor_page_count),
                pageSize: pageSize) / 1024)
        let cacheKB = Int64(UInt64(stats.external_page_count) * pageSize / 1024)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        return MachineMemory(
            totalKB: totalKB, availKB: max(0, totalKB - usedKB), usedKB: usedKB,
            buffcacheKB: cacheKB, swapTotalKB: Int64(swap.xsu_total) / 1024,
            swapUsedKB: Int64(swap.xsu_used) / 1024)
    }

    private func coreLoads() -> [Double] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return [] }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var current: [(used: Double, total: Double)] = []
        for index in 0..<Int(cpuCount) {
            let base = index * Int(CPU_STATE_MAX)
            let user = Double(info[base + Int(CPU_STATE_USER)])
            let system = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = Double(info[base + Int(CPU_STATE_NICE)])
            let idle = Double(info[base + Int(CPU_STATE_IDLE)])
            current.append((used: user + system + nice, total: user + system + nice + idle))
        }
        defer { prevCores = current }
        guard prevCores.count == current.count else {
            return current.map { _ in 0 }
        }
        return zip(prevCores, current).map { previous, now in
            let usedDelta = now.used - previous.used
            let totalDelta = now.total - previous.total
            guard totalDelta > 0 else { return 0 }
            return min(100, max(0, usedDelta / totalDelta * 100))
        }
    }

    private func network(dt: Double) -> MachineNetwork {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return MachineNetwork()
        }
        defer { freeifaddrs(addresses) }
        var current: [String: (rx: UInt64, tx: UInt64)] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr,
                addr.pointee.sa_family == UInt8(AF_LINK),
                let dataPointer = entry.pointee.ifa_data
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name != "lo0" else { continue }
            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            let existing = current[name] ?? (rx: 0, tx: 0)
            current[name] = (
                rx: existing.rx + UInt64(data.ifi_ibytes),
                tx: existing.tx + UInt64(data.ifi_obytes)
            )
        }
        defer { prevNet = current }
        guard dt > 0 else { return MachineNetwork() }
        var interfaces: [MachineNetInterface] = []
        var rxTotal = 0.0
        var txTotal = 0.0
        for (name, counters) in current.sorted(by: { $0.key < $1.key }) {
            guard let previous = prevNet[name] else { continue }
            let rx = counters.rx >= previous.rx ? Double(counters.rx - previous.rx) / dt : 0
            let tx = counters.tx >= previous.tx ? Double(counters.tx - previous.tx) / dt : 0
            let virtualPrefixes = ["utun", "awdl", "llw", "bridge", "ap", "gif", "stf", "anpi"]
            let isVirtual = virtualPrefixes.contains { name.hasPrefix($0) }
            if rx == 0, tx == 0 { continue }
            interfaces.append(
                MachineNetInterface(n: name, rxBps: rx, txBps: tx, virtual: isVirtual))
            if !isVirtual {
                rxTotal += rx
                txTotal += tx
            }
        }
        return MachineNetwork(ifaces: interfaces, rxBps: rxTotal, txBps: txTotal)
    }

    private nonisolated static func readProcesses() async -> [MachineProcess] {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,user=,%cpu=,%mem=,rss=,comm="]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            var rows: [MachineProcess] = []
            for line in text.split(separator: "\n") {
                let columns = line.split(
                    separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
                guard columns.count == 6, let pid = Int(columns[0]),
                    let cpu = Double(columns[2]), let mem = Double(columns[3]),
                    let rss = Int64(columns[4])
                else { continue }
                let command = String(columns[5])
                let name = (command as NSString).lastPathComponent
                rows.append(
                    MachineProcess(
                        pid: pid, user: String(columns[1]), cpu: cpu, mem: mem, rssKB: rss,
                        name: name, cmd: command))
            }
            return rows.sorted { $0.cpu > $1.cpu }
        }.value
    }

    private nonisolated static func battery() -> MachineBattery? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: #"(\d+)%; (\w[\w ]*)"#, options: .regularExpression)
        else { return nil }
        let match = text[range]
        let parts = match.split(separator: ";")
        guard parts.count == 2, let percent = Int(parts[0].dropLast()) else { return nil }
        let status = parts[1].trimmingCharacters(in: .whitespaces)
        return MachineBattery(percent: percent, status: status.capitalized)
    }

    private func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}
