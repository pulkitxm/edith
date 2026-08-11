import AppKit
import Foundation

private struct MachineLiveMetrics {
    var sample: MachineSample?
    var cpuHistory: [Double] = []
    var memHistory: [Double] = []
    var netRxHistory: [Double] = []
    var netTxHistory: [Double] = []
    var diskReadHistory: [Double] = []
    var diskWriteHistory: [Double] = []
}

@MainActor
public final class MachineSession: ObservableObject {
    public let machine: Machine
    public nonisolated var id: UUID { machine.id }

    @Published public private(set) var state: MachineConnectionState = .disconnected
    @Published public private(set) var hello: MachineHello?
    @Published public private(set) var slow: MachineSlow?
    @Published private var liveMetrics = MachineLiveMetrics()
    @Published public private(set) var docker = DockerAvailability(status: .unknown)
    @Published public private(set) var containersLoaded = false
    @Published public private(set) var containers: [DockerContainer] = []
    @Published public private(set) var images: [DockerImage] = []
    @Published public private(set) var volumes: [DockerVolume] = []
    @Published public private(set) var diskUsage: [DockerDiskUsage] = []
    @Published public private(set) var networks: [DockerNetwork] = []
    @Published public private(set) var services: [SystemdService] = []
    @Published public private(set) var facts = MachineSessionSummary()
    @Published public private(set) var activeForwards: Set<UUID> = []
    @Published public private(set) var mount: MachineMount?
    @Published public private(set) var mountHealth: MountHealth?
    @Published public private(set) var isRemounting = false
    @Published public private(set) var isLocal: Bool

    public static let historyLength = 60

    public var sample: MachineSample? { liveMetrics.sample }
    public var cpuHistory: [Double] { liveMetrics.cpuHistory }
    public var memHistory: [Double] { liveMetrics.memHistory }
    public var netRxHistory: [Double] { liveMetrics.netRxHistory }
    public var netTxHistory: [Double] { liveMetrics.netTxHistory }
    public var diskReadHistory: [Double] { liveMetrics.diskReadHistory }
    public var diskWriteHistory: [Double] { liveMetrics.diskWriteHistory }

    private let connection: SSHConnection?
    private let localSampler: LocalMachineSampler?
    private var metricsStream: SSHLineStream?
    private var supervisor: Task<Void, Never>?
    private var dockerTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private var localTask: Task<Void, Never>?
    private var metricsRestartTask: Task<Void, Never>?
    private var metricsWatchdog: Task<Void, Never>?
    private var lastMetricAt: Date?
    private var metricsFailures = 0
    private var probeTask: Task<Void, Never>?
    private var mountTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var reconnects = true
    private var rememberedForwards: [UUID: PortForward] = [:]
    private var dockerObserverCount = 0
    private var dockerRefreshRunning = false
    private var dockerInventoryRefreshRunning = false

    public init(machine: Machine, local: Bool = false, observesWakeRequests: Bool = true) {
        self.machine = machine
        isLocal = local
        connection = local ? nil : SSHConnection(machine: machine)
        localSampler = local ? LocalMachineSampler() : nil
        if observesWakeRequests { observeWake() }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    public var connectionRef: SSHConnection? { connection }

    public func start() {
        guard !state.isConnected, !state.isBusy else { return }
        guard !machine.isMissing else {
            state = .failed(message: "This machine is no longer configured.")
            return
        }
        if isLocal {
            startLocal()
            return
        }
        state = .connecting
        connect(afterFailures: 0, closingFirst: false)
    }

    public func stop() {
        reconnects = false
        cancelWork()
        rememberedForwards.removeAll()
        activeForwards.removeAll()
        let connection = connection
        Task { await connection?.disconnect() }
        state = .disconnected
    }

    public func retry() {
        guard !isLocal else {
            stop()
            start()
            return
        }
        guard !machine.isMissing else {
            state = .failed(message: "This machine is no longer configured.")
            return
        }
        cancelWork()
        state = .connecting
        connect(afterFailures: 0, closingFirst: true)
    }

    private func cancelWork() {
        supervisor?.cancel()
        supervisor = nil
        dockerTask?.cancel()
        dockerTask = nil
        latencyTask?.cancel()
        latencyTask = nil
        localTask?.cancel()
        localTask = nil
        metricsRestartTask?.cancel()
        metricsRestartTask = nil
        metricsWatchdog?.cancel()
        metricsWatchdog = nil
        probeTask?.cancel()
        probeTask = nil
        mountTask?.cancel()
        mountTask = nil
        metricsStream?.cancel()
        metricsStream = nil
    }

    private func connect(afterFailures failures: Int, closingFirst: Bool) {
        reconnects = true
        supervisor?.cancel()
        supervisor = Task { [weak self] in
            if closingFirst {
                await self?.connection?.disconnect()
            }
            var failures = failures
            while !Task.isCancelled {
                if failures > 0 {
                    try? await Task.sleep(
                        for: .seconds(MachineReconnect.delay(afterFailures: failures)))
                }
                guard !Task.isCancelled, let self, let connection else { return }
                do {
                    try await connection.connect()
                    guard !Task.isCancelled else { return }
                    await replayForwards(on: connection)
                    guard !Task.isCancelled else { return }
                    state = .connected(latencyMillis: nil)
                    startMetricsStream()
                    startDockerPolling()
                    startLatencyProbe()
                    startMountWatch()
                    await loadFacts()
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    let failure = Self.failure(from: error)
                    guard failure.isRecoverable else {
                        state = .failed(message: failure.message)
                        return
                    }
                    failures += 1
                    state = MachineReconnect.state(
                        afterFailures: failures, reason: failure.message)
                }
            }
        }
    }

    private static func failure(from error: Error) -> SSHConnectFailure {
        if case let SSHConnectionError.connectFailed(failure) = error { return failure }
        return SSHConnectFailure(message: error.localizedDescription, isRecoverable: true)
    }

    private func handleDrop() {
        guard state.isConnected else { return }
        cancelWork()
        state = .reconnecting
        connect(afterFailures: 0, closingFirst: false)
    }

    private func observeWake() {
        guard !isLocal else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconnectAfterWake() }
        }
    }

    private func reconnectAfterWake() {
        guard reconnects, !machine.isMissing else { return }
        Task { await restoreMount() }
        switch state {
        case .connected: probeConnection()
        case .reconnecting, .failed:
            state = .reconnecting
            connect(afterFailures: 0, closingFirst: false)
        case .connecting, .disconnected: break
        }
    }

    private func probeConnection() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            guard let self, let connection, state.isConnected else { return }
            let alive = await connection.masterIsAlive()
            guard !Task.isCancelled else { return }
            guard !alive else { return }
            handleDrop()
        }
    }

    private func startLocal() {
        state = .connected(latencyMillis: 0)
        hello = localSampler?.hello()
        localTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, let sampler = localSampler else { return }
                let next = await sampler.sample()
                guard !Task.isCancelled else { return }
                apply(sample: next)
                if tick % 15 == 0 {
                    slow = sampler.slow()
                }
                tick += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public static let metricsSilenceLimit: TimeInterval = 30

    nonisolated static func metricsRestartDelay(failures: Int) -> TimeInterval {
        let steps = min(max(0, failures), 8)
        return min(3 * pow(2, Double(steps)), 60)
    }

    private func startMetricsWatchdog() {
        metricsWatchdog?.cancel()
        metricsWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                guard state.isConnected, metricsStream != nil, let last = lastMetricAt else {
                    continue
                }
                guard Date().timeIntervalSince(last) > Self.metricsSilenceLimit else { continue }
                metricsStream?.cancel()
                metricsStream = nil
                handleMetricsStreamEnded()
                return
            }
        }
    }

    private func startMetricsStream() {
        guard let connection, let script = MachineCollector.script() else { return }
        let process = connection.streamProcess(command: MachineCollector.streamCommand)
        let stream = SSHLineStream(
            process: process, stdinData: script,
            onLine: { [weak self] line, isStderr in
                guard !isStderr, let record = MachineMetricsDecoder.decode(line: line) else {
                    return
                }
                Task { @MainActor in self?.apply(record: record) }
            },
            onExit: { [weak self] _ in
                Task { @MainActor in self?.handleMetricsStreamEnded() }
            })
        do {
            try stream.start()
            metricsStream = stream
            lastMetricAt = Date()
            startMetricsWatchdog()
        } catch {
            handleMetricsStreamEnded()
        }
    }

    private func handleMetricsStreamEnded() {
        guard state.isConnected else { return }
        metricsStream = nil
        metricsWatchdog?.cancel()
        metricsWatchdog = nil
        metricsRestartTask?.cancel()
        let delay = Self.metricsRestartDelay(failures: metricsFailures)
        metricsFailures += 1
        metricsRestartTask = Task { [weak self] in
            guard let self, let connection else { return }
            guard await connection.masterIsAlive() else {
                handleDrop()
                return
            }
            try? await Task.sleep(for: .seconds(delay))
            guard state.isConnected, metricsStream == nil else { return }
            startMetricsStream()
        }
    }

    private func apply(record: MachineMetricRecord) {
        lastMetricAt = Date()
        metricsFailures = 0
        switch record {
        case let .hello(value): hello = value
        case let .sample(value): apply(sample: value)
        case let .slow(value): slow = value
        }
    }

    func apply(sample value: MachineSample) {
        var next = liveMetrics
        next.sample = value
        next.cpuHistory = Self.appending(value.cpu.total, to: next.cpuHistory)
        next.memHistory = Self.appending(value.mem.usedPercent, to: next.memHistory)
        next.netRxHistory = Self.appending(value.net.rxBps, to: next.netRxHistory)
        next.netTxHistory = Self.appending(value.net.txBps, to: next.netTxHistory)
        next.diskReadHistory = Self.appending(value.disk.readBps, to: next.diskReadHistory)
        next.diskWriteHistory = Self.appending(value.disk.writeBps, to: next.diskWriteHistory)
        liveMetrics = next
    }

    public static func appending(_ value: Double, to history: [Double]) -> [Double] {
        guard !history.isEmpty else {
            return Array(repeating: value, count: historyLength)
        }
        var next = history
        next.append(value)
        if next.count > historyLength {
            next.removeFirst(next.count - historyLength)
        }
        return next
    }

    private func startLatencyProbe() {
        latencyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let connection else { return }
                let latency = await connection.latencyMillis()
                guard !Task.isCancelled else { return }
                if let latency, state.isConnected {
                    state = .connected(latencyMillis: latency)
                } else if state.isConnected, !(await connection.masterIsAlive()) {
                    handleDrop()
                    return
                }
                try? await Task.sleep(
                    for: .seconds(MachineResourcePolicy.latencyProbeInterval))
            }
        }
    }

    public func refreshDockerNow() {
        Task { await refreshDocker() }
    }

    public func beginDockerObservation() {
        dockerObserverCount += 1
        refreshDockerNow()
    }

    public func endDockerObservation() {
        dockerObserverCount = max(0, dockerObserverCount - 1)
    }

    var currentDockerPollInterval: TimeInterval {
        MachineResourcePolicy.dockerPollInterval(observerCount: dockerObserverCount)
    }

    private func startDockerPolling() {
        dockerTask = Task { [weak self] in
            guard let self, let connection else { return }
            let version = try? await connection.run(DockerCommands.version(), timeout: 20)
            guard !Task.isCancelled else { return }
            var availability = DockerParsing.availability(
                versionOutput: version?.stdoutText ?? "", versionStderr: version?.stderrText ?? "",
                status: version?.status ?? 1)
            if case let .available(serverVersion, _) = availability.status {
                let compose = try? await connection.run(
                    DockerCommands.composeVersion(), timeout: 15)
                availability = DockerAvailability(
                    status: .available(
                        serverVersion: serverVersion, hasCompose: compose?.succeeded == true))
            }
            guard !Task.isCancelled else { return }
            docker = availability
            guard availability.isAvailable else { return }
            await refreshImagesAndVolumes()
            while !Task.isCancelled {
                await refreshDocker()
                try? await Task.sleep(
                    for: .seconds(
                        MachineResourcePolicy.dockerPollInterval(
                            observerCount: dockerObserverCount)))
            }
        }
    }

    private func refreshDocker() async {
        guard let connection, docker.isAvailable, !dockerRefreshRunning else { return }
        dockerRefreshRunning = true
        defer { dockerRefreshRunning = false }
        guard
            let result = try? await connection.run(
                DockerCommands.containersWithStats(), timeout: 30), result.succeeded
        else { return }
        let sections = result.stdoutText.components(separatedBy: DockerCommands.listSeparator)
        let parsed = DockerParsing.containers(psOutput: sections.first ?? "")
        containers =
            sections.count > 1
            ? DockerParsing.applyStats(sections[1], to: parsed) : parsed
        containersLoaded = true
    }

    public func refreshImagesAndVolumes() async {
        guard let connection, docker.isAvailable, !dockerInventoryRefreshRunning else { return }
        dockerInventoryRefreshRunning = true
        defer { dockerInventoryRefreshRunning = false }
        async let imagesResult = try? connection.run(DockerCommands.images(), timeout: 30)
        async let volumesResult = try? connection.run(DockerCommands.volumes(), timeout: 30)
        async let usageResult = try? connection.run(DockerCommands.diskUsage(), timeout: 30)
        async let verboseResult = try? connection.run(
            DockerCommands.diskUsageVerbose(), timeout: 60)
        let (imagesOut, volumesOut, usageOut, verboseOut) = await (
            imagesResult, volumesResult, usageResult, verboseResult
        )
        images = DockerParsing.images(imagesOut?.stdoutText ?? "")
        if let networksOut = try? await connection.run(DockerCommands.networks(), timeout: 20) {
            networks = DockerParsing.networks(networksOut.stdoutText)
        }
        let details = DockerParsing.volumeDetails(
            systemDFOutput: verboseOut?.stdoutText ?? "")
        volumes = DockerParsing.volumes(volumesOut?.stdoutText ?? "").map { volume in
            var updated = volume
            if let detail = details[volume.name] {
                updated.sizeBytes = detail.0
                updated.containerCount = detail.1
            }
            return updated
        }
        diskUsage = DockerParsing.diskUsage(usageOut?.stdoutText ?? "")
    }

    @discardableResult
    public func runDocker(_ command: String) async -> Result<String, Error> {
        guard let connection else {
            return .failure(
                SSHConnectionError.commandFailed(
                    command: command, status: 1, stderr: "Not connected."))
        }
        do {
            let result = try await connection.run(command, timeout: 120)
            guard result.succeeded else {
                let message = result.stderrText.isEmpty ? result.stdoutText : result.stderrText
                return .failure(
                    SSHConnectionError.commandFailed(
                        command: command, status: result.status, stderr: message))
            }
            await refreshDocker()
            return .success(result.stdoutText)
        } catch {
            return .failure(error)
        }
    }

    public func runCommand(
        _ command: String, stdin: Data? = nil, timeout: TimeInterval = 60
    ) async -> Result<String, Error> {
        guard let connection else {
            return await runLocalCommand(command)
        }
        do {
            let result = try await connection.run(command, stdin: stdin, timeout: timeout)
            let output = result.stdoutText + result.stderrText
            guard result.succeeded else {
                return .failure(
                    SSHConnectionError.commandFailed(
                        command: command, status: result.status, stderr: output))
            }
            return .success(output)
        } catch {
            return .failure(error)
        }
    }

    private func runLocalCommand(_ command: String) async -> Result<String, Error> {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return .failure(error)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                return .failure(
                    SSHConnectionError.commandFailed(
                        command: command, status: process.terminationStatus, stderr: text))
            }
            return .success(text)
        }.value
    }

    public func refreshServices() async {
        guard !isLocal, let connection else { return }
        guard let result = try? await connection.run(ServiceCommands.list(), timeout: 30) else {
            return
        }
        services = ServiceCommands.parse(result.stdoutText)
    }

    private func loadFacts() async {
        guard let connection else { return }
        async let whoResult = try? connection.run(MachineFacts.whoCommand, timeout: 15)
        async let macResult = try? connection.run(MachineFacts.macAddressCommand, timeout: 15)
        async let updatesResult = try? connection.run(MachineFacts.updatesCommand, timeout: 45)
        let (who, mac, updates) = await (whoResult, macResult, updatesResult)
        facts = MachineSessionSummary(
            who: MachineFacts.parseWho(who?.stdoutText ?? ""),
            updatesAvailable: MachineFacts.parseUpdates(updates?.stdoutText ?? ""),
            macAddress: MachineFacts.parseMACAddress(mac?.stdoutText ?? ""))
    }

    private func startMountWatch() {
        guard !isLocal else { return }
        mountTask?.cancel()
        mountTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await restoreMount()
                try? await Task.sleep(for: .seconds(MachineResourcePolicy.mountCheckInterval))
            }
        }
    }

    @discardableResult
    public func restoreMount() async -> MountRepair {
        guard !isLocal, !isRemounting else { return .nothingToDo }
        guard let wanted = MachineMounts.recorded(for: machine) else {
            mount = await MachineMounts.current(for: machine)
            mountHealth = mount == nil ? nil : .mounted
            return .nothingToDo
        }
        let health = await MachineMounts.health(of: wanted)
        mount = wanted
        mountHealth = health
        guard health.needsRepair else { return .healthy(wanted) }
        isRemounting = true
        let repair = await MachineMounts.restore(machine: machine)
        isRemounting = false
        switch repair {
        case let .remounted(landed), let .healthy(landed):
            mount = landed
            mountHealth = .mounted
        case let .failed(record, _):
            mount = record
        case .nothingToDo:
            mount = nil
            mountHealth = nil
        }
        return repair
    }

    private func replayForwards(on connection: SSHConnection) async {
        let forwards = Array(rememberedForwards.values)
        var failedIDs: Set<UUID> = []
        for forward in forwards {
            do {
                try await connection.addForward(forward)
            } catch {
                failedIDs.insert(forward.id)
            }
        }
        rememberedForwards = MachineForwardReplay.retainedForwards(
            rememberedForwards, failedIDs: failedIDs)
        activeForwards = Set(rememberedForwards.keys)
    }

    public func setForward(_ forward: PortForward, active: Bool) async -> String? {
        guard let connection else { return "Not connected." }
        if active {
            do {
                try await connection.addForward(forward)
                rememberedForwards[forward.id] = forward
                activeForwards.insert(forward.id)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        await connection.cancelForward(forward)
        rememberedForwards.removeValue(forKey: forward.id)
        activeForwards.remove(forward.id)
        return nil
    }

    public func listFiles(path: String) async -> Result<[RemoteFileEntry], Error> {
        if isLocal {
            return .success(Self.listLocalFiles(path: path))
        }
        guard let connection else { return .success([]) }
        do {
            let result = try await connection.run(
                FileListing.command(path: path, showHidden: true), timeout: 45)
            let entries = FileListing.parse(output: result.stdoutText, parent: path)
            if entries.isEmpty, !result.succeeded {
                let message =
                    result.stderrText.isEmpty
                    ? "Could not read that folder." : result.stderrText
                return .failure(
                    SSHConnectionError.commandFailed(
                        command: "list", status: result.status, stderr: message))
            }
            return .success(entries)
        } catch {
            return .failure(error)
        }
    }

    public nonisolated static func searchLocalFiles(
        root: String, query: String, limit: Int = 300
    ) -> [RemoteFileEntry] {
        guard !query.isEmpty else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard
            let walker = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var found: [RemoteFileEntry] = []
        for case let url as URL in walker {
            guard found.count < limit else { break }
            guard url.lastPathComponent.localizedCaseInsensitiveContains(query) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let path = FilePathKey.anchor(url.path, to: root)
            found.append(
                RemoteFileEntry(
                    name: url.lastPathComponent, path: path,
                    kind: values?.isDirectory == true ? .directory : .file,
                    sizeBytes: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate))
        }
        return found
    }

    nonisolated static func listLocalFiles(path: String) -> [RemoteFileEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        guard
            let urls = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys,
                options: [])
        else { return [] }
        let entries = urls.map { url -> RemoteFileEntry in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let kind: FileEntryKind =
                values?.isSymbolicLink == true
                ? .symlink : (values?.isDirectory == true ? .directory : .file)
            return RemoteFileEntry(
                name: url.lastPathComponent,
                path: FileListing.join(parent: path, name: url.lastPathComponent), kind: kind,
                sizeBytes: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate)
        }
        return FileListing.sorted(entries)
    }
}

enum MachineForwardReplay {
    static func retainedForwards(
        _ forwards: [UUID: PortForward], failedIDs: Set<UUID>
    ) -> [UUID: PortForward] {
        forwards.filter { !failedIDs.contains($0.key) }
    }
}
