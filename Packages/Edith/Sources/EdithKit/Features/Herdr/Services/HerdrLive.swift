import Foundation

public enum HerdrLive {
    static let remoteLeaseDuration = Duration.seconds(20)
    static let fallbackSnapshotDelay = Duration.seconds(2)

    public static func watch(_ yield: @escaping @Sendable ([HerdrHostSnapshot]) -> Void) async {
        let fleet = FleetBag(yield: yield)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await watchLocal(fleet) }
            group.addTask {
                await watchRemotes(MachineRegistry.machines()) { machine in
                    await watchRemoteLease(machine, fleet)
                }
            }
            await group.waitForAll()
        }
    }

    static func watchRemotes(
        _ machines: [Machine],
        maximumInFlight: Int = HerdrFleetScheduler.defaultMaximumInFlight,
        watcher: @escaping @Sendable (Machine) async -> Void
    ) async {
        await HerdrFleetScheduler.cycle(
            machines, maximumInFlight: maximumInFlight, operation: watcher)
    }

    private static func watchLocal(_ fleet: FleetBag) async {
        while !Task.isCancelled {
            let sockets = HerdrSocketDiscovery.local()
            if sockets.isEmpty {
                let present = HerdrCollector.executable() != nil
                fleet.put(
                    .local(
                        herdrPresent: present,
                        error: present
                            ? "no herdr server is running" : "herdr is not on PATH"))
                try? await Task.sleep(for: .seconds(present ? 2 : 8))
                continue
            }
            await runHost(
                sockets: sockets,
                connect: { try HerdrSocketClient.unix(path: $0) },
                machineID: HerdrHostSnapshot.localID,
                machineName: "This Mac",
                machineIsLocal: true,
                sshTarget: nil,
                fleet: fleet)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func watchRemoteLease(_ machine: Machine, _ fleet: FleetBag) async {
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        do {
            try await connection.connect()
        } catch {
            fleet.put(
                HerdrHostSnapshot(
                    id: machine.id.uuidString, name: machine.name, isLocal: false,
                    sshTarget: machine.sshTarget, herdrPresent: false, reachable: false,
                    error: error.localizedDescription))
            try? await Task.sleep(for: .seconds(5))
            return
        }
        guard !Task.isCancelled else { return }
        let sockets = await remoteSockets(connection)
        guard !Task.isCancelled else { return }
        if sockets.isEmpty {
            let collected = await HerdrCollector.collect(.machine(machine))
            if let host = collected.first { fleet.put(host) }
            try? await Task.sleep(for: .seconds(8))
            return
        }
        await runHostLease(
            sockets: sockets,
            connect: { try HerdrSocketClient.ssh(connection, socketPath: $0) },
            machineID: machine.id.uuidString,
            machineName: machine.name,
            machineIsLocal: false,
            sshTarget: machine.sshTarget,
            fleet: fleet)
    }

    private static func runHostLease(
        sockets: [(name: String, path: String)],
        connect: @escaping @Sendable (String) throws -> HerdrSocketClient,
        machineID: String, machineName: String, machineIsLocal: Bool, sshTarget: String?,
        fleet: FleetBag
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await runHost(
                    sockets: sockets, connect: connect, machineID: machineID,
                    machineName: machineName, machineIsLocal: machineIsLocal,
                    sshTarget: sshTarget, fleet: fleet)
            }
            group.addTask { try? await Task.sleep(for: remoteLeaseDuration) }
            await group.next()
            group.cancelAll()
            await group.waitForAll()
        }
    }

    private static func remoteSockets(_ connection: SSHConnection) async -> [(
        name: String, path: String
    )] {
        let result = try? await connection.run(
            HerdrSocketDiscovery.remoteProbeCommand(), timeout: 12)
        return HerdrSocketDiscovery.sockets(fromRemoteListing: result?.stdoutText ?? "")
    }

    private static func runHost(
        sockets: [(name: String, path: String)],
        connect: @escaping @Sendable (String) throws -> HerdrSocketClient,
        machineID: String, machineName: String, machineIsLocal: Bool, sshTarget: String?,
        fleet: FleetBag
    ) async {
        let sessions = SessionBag(
            machineID: machineID, machineName: machineName, machineIsLocal: machineIsLocal,
            sshTarget: sshTarget)
        await withTaskGroup(of: Void.self) { group in
            for socket in sockets {
                group.addTask {
                    await runSession(
                        socket: socket, connect: connect, sessions: sessions, fleet: fleet)
                }
            }
            await group.waitForAll()
        }
    }

    private static func runSession(
        socket: (name: String, path: String),
        connect: @escaping @Sendable (String) throws -> HerdrSocketClient,
        sessions: SessionBag,
        fleet: FleetBag
    ) async {
        do {
            fleet.put(
                sessions.applySnapshot(
                    session: socket.name,
                    text: try await snapshot(path: socket.path, connect: connect)))
        } catch {
            fleet.put(sessions.failed(session: socket.name, error: error.localizedDescription))
            return
        }

        while !Task.isCancelled {
            let stream: HerdrSocketClient
            do {
                stream = try connect(socket.path)
            } catch {
                fleet.put(sessions.failed(session: socket.name, error: error.localizedDescription))
                return
            }
            await withTaskCancellationHandler {
                defer { stream.close() }
                do {
                    let events = stream.events
                    try await stream.subscribeBoard()
                    for await line in events {
                        fleet.put(sessions.applyEvent(session: socket.name, text: line))
                    }
                } catch {
                    fleet.put(
                        sessions.failed(session: socket.name, error: error.localizedDescription))
                }
            } onCancel: {
                stream.close()
            }
            try? await Task.sleep(for: fallbackSnapshotDelay)
            guard !Task.isCancelled else { return }
            do {
                fleet.put(
                    sessions.applySnapshot(
                        session: socket.name,
                        text: try await snapshot(path: socket.path, connect: connect)))
            } catch {
                fleet.put(sessions.failed(session: socket.name, error: error.localizedDescription))
            }
        }
    }

    static func snapshot(
        path: String,
        connect: @escaping @Sendable (String) throws -> HerdrSocketClient
    ) async throws -> String {
        let stream = try connect(path)
        defer { stream.close() }
        return try await stream.snapshot()
    }
}

private final class FleetBag: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String: HerdrHostSnapshot] = [:]
    private let yield: @Sendable ([HerdrHostSnapshot]) -> Void

    init(yield: @escaping @Sendable ([HerdrHostSnapshot]) -> Void) {
        self.yield = yield
    }

    func put(_ host: HerdrHostSnapshot) {
        lock.lock()
        hosts[host.id] = host
        var ordered: [HerdrHostSnapshot] = []
        if let local = hosts[HerdrHostSnapshot.localID] { ordered.append(local) }
        for machine in MachineRegistry.machines() {
            if let host = hosts[machine.id.uuidString] { ordered.append(host) }
        }
        lock.unlock()
        yield(ordered)
    }
}

private final class SessionBag: @unchecked Sendable {
    let machineID: String
    let machineName: String
    let machineIsLocal: Bool
    let sshTarget: String?
    private let lock = NSLock()
    private var caches: [String: HerdrBoardCache] = [:]
    private var errors: [String: String] = [:]

    init(
        machineID: String, machineName: String, machineIsLocal: Bool, sshTarget: String?
    ) {
        self.machineID = machineID
        self.machineName = machineName
        self.machineIsLocal = machineIsLocal
        self.sshTarget = sshTarget
    }

    func applySnapshot(session: String, text: String) -> HerdrHostSnapshot {
        let cache = lockedCache(for: session)
        _ = cache.applySnapshot(text)
        lock.lock()
        errors[session] = nil
        let host = hostLocked()
        lock.unlock()
        return host
    }

    func applyEvent(session: String, text: String) -> HerdrHostSnapshot {
        let cache = lockedCache(for: session)
        _ = cache.applyEvent(text)
        lock.lock()
        let host = hostLocked()
        lock.unlock()
        return host
    }

    func failed(session: String, error: String) -> HerdrHostSnapshot {
        lock.lock()
        if caches[session]?.agents.isEmpty != false {
            errors[session] = error
        }
        let host = hostLocked()
        lock.unlock()
        return host
    }

    private func lockedCache(for session: String) -> HerdrBoardCache {
        lock.lock()
        defer { lock.unlock() }
        if let existing = caches[session] { return existing }
        let created = HerdrBoardCache(
            context: HerdrBoardContext(
                session: session, machineID: machineID, machineName: machineName,
                machineIsLocal: machineIsLocal, sshTarget: sshTarget))
        caches[session] = created
        return created
    }

    private func hostLocked() -> HerdrHostSnapshot {
        let all = caches.values.flatMap(\.agents)
        let error = all.isEmpty ? errors.values.compactMap { $0 }.first : nil
        if machineIsLocal {
            return .local(herdrPresent: true, agents: all, error: error)
        }
        return HerdrHostSnapshot(
            id: machineID, name: machineName, isLocal: false, sshTarget: sshTarget,
            herdrPresent: true, reachable: true, agents: all, error: error)
    }
}
