import EdithExtensionSupport
import Foundation

@MainActor public final class MachinePeerTransport {
    private var connections: [UUID: SSHConnection] = [:]
    private var connectionJobs: [UUID: Task<SSHConnection, Error>] = [:]
    private var forwards: [Int: PortForward] = [:]
    private var stopped = false

    public let snapshots = MachineUsageSnapshotStore()

    public init() {}

    public func run(_ machine: Machine, command: String, stdin: Data?, timeout: TimeInterval)
        async throws -> String
    {
        let connection = try await connected(machine)
        let result = try await connection.run(
            command, stdin: stdin, timeout: timeout, maximumOutputBytes: 6 * 1_024 * 1_024)
        try Task.checkCancellation()
        guard result.succeeded else { throw ExtensionPeerError.rejected(result.stderrText) }
        return result.successfulCommandText
    }

    public func forward(_ machine: Machine, forward: PortForward) async throws -> Bool {
        guard
            forwards[forward.localPort].map({
                $0.machineID == forward.machineID && $0.remoteHost == forward.remoteHost
                    && $0.remotePort == forward.remotePort
            }) ?? true
        else {
            throw ExtensionPeerError.rejected("That local port already belongs to another forward.")
        }
        let connection = try await connected(machine)
        if let active = forwards[forward.localPort], active.machineID == machine.id { return true }
        try await connection.addForward(forward)
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        forwards[forward.localPort] = forward
        return true
    }

    public func collectUsage(_ machine: Machine, force: Bool) async throws -> Data {
        let connection = try await connected(machine)
        guard let platform = await connection.remotePlatform else {
            throw ExtensionPeerError.unavailable
        }
        guard let endpoint = ExtensionPeerEndpoint.current(owner: "usage") else {
            throw ExtensionPeerError.rejected(
                "Enable Usage to collect receipts from saved machines.")
        }
        let command = try MachineRemoteUsageOperation.command(platform: platform, force: force)
        let result = try await connection.run(
            command, timeout: 900,
            maximumOutputBytes: MachineUsageCollectionService.maximumDocumentBytes)
        try Task.checkCancellation()
        guard result.succeeded else { throw ExtensionPeerError.rejected(result.stderrText) }
        guard var document = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        else {
            throw ExtensionPeerError.invalidRequest
        }
        var context = document["context"] as? [String: Any] ?? ["projects": []]
        context["machineID"] = machine.id.uuidString
        document["context"] = context
        let snapshot = try snapshots.insert(
            JSONSerialization.data(withJSONObject: document), machine: machine)
        defer { snapshots.remove(snapshot.collectionID) }
        let projected = try await endpoint.invoke(
            "usage.machines.project", payload: JSONEncoder().encode(snapshot), timeout: 900)
        let descriptor = try JSONDecoder().decode(Projected.self, from: projected)
        do {
            guard descriptor.byteCount > 0,
                descriptor.byteCount <= MachineUsageCollectionService.maximumDocumentBytes,
                descriptor.sha256.count == 64,
                descriptor.sha256.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) })
            else { throw ExtensionPeerError.invalidRequest }
            var document = Data()
            while document.count < descriptor.byteCount {
                try Task.checkCancellation()
                let request = ResultRequest(
                    collectionID: descriptor.collectionID, offset: document.count,
                    maximumBytes: MachineUsageCollectionService.maximumChunkBytes)
                let response = try await endpoint.invoke(
                    "usage.machines.result", payload: JSONEncoder().encode(request), timeout: 60)
                let chunk = try JSONDecoder().decode(Chunk.self, from: response)
                guard chunk.offset == document.count, !chunk.data.isEmpty,
                    chunk.data.count <= request.maximumBytes,
                    document.count + chunk.data.count <= descriptor.byteCount,
                    chunk.finished == (document.count + chunk.data.count == descriptor.byteCount)
                else { throw ExtensionPeerError.invalidRequest }
                document.append(chunk.data)
            }
            guard MachineUsageReceiptSnapshot.hash(document) == descriptor.sha256 else {
                throw ExtensionPeerError.invalidRequest
            }
            await cancelProjection(endpoint, id: descriptor.collectionID)
            return document
        } catch {
            await cancelProjection(endpoint, id: descriptor.collectionID)
            throw error
        }
    }

    private struct Projected: Decodable {
        let collectionID: UUID
        let byteCount: Int
        let sha256: String
        let generatedAt: String
    }
    private struct ResultRequest: Encodable {
        let collectionID: UUID; let offset: Int; let maximumBytes: Int
    }
    private struct Chunk: Decodable { let offset: Int; let data: Data; let finished: Bool }
    private func cancelProjection(_ endpoint: ExtensionPeerEndpoint, id: UUID) async {
        let payload = Data("{\"collectionID\":\"\(id.uuidString)\"}".utf8)
        await Task.detached {
            _ = try? await endpoint.invoke("usage.machines.cancel", payload: payload, timeout: 15)
        }.value
    }

    public func shutdown() async {
        stopped = true
        snapshots.shutdown()
        let jobs = connectionJobs.values
        for job in jobs { job.cancel() }
        connectionJobs = [:]
        for connection in connections.values { await connection.disconnect() }
        connections = [:]
        forwards = [:]
        for job in jobs {
            if let connection = try? await job.value { await connection.disconnect() }
        }
    }

    private func connected(_ machine: Machine) async throws -> SSHConnection {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        if let existing = connections[machine.id] {
            if existing.machine == machine, await existing.masterIsAlive() { return existing }
            await existing.disconnect()
            connections.removeValue(forKey: machine.id)
            forwards = forwards.filter { $0.value.machineID != machine.id }
        }
        if let job = connectionJobs[machine.id] {
            let connection = try await job.value
            guard connection.machine == machine else { throw ExtensionPeerError.invalidRequest }
            return connection
        }
        guard connections.count + connectionJobs.count < 16 else {
            throw ExtensionPeerError.unavailable
        }
        let connection = SSHConnection(machine: machine)
        let job = Task {
            do {
                try await connection.connect()
                try Task.checkCancellation()
                return connection
            } catch {
                await connection.disconnect()
                throw error
            }
        }
        connectionJobs[machine.id] = job
        defer { connectionJobs.removeValue(forKey: machine.id) }
        let live = try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
        guard !stopped else { await live.disconnect(); throw ExtensionPeerError.unavailable }
        connections[machine.id] = live
        return live
    }
}

public enum MachineRemoteUsageOperation {
    public static func command(platform: RemoteMachinePlatform, force: Bool) throws -> String {
        guard platform != .windows else {
            throw ExtensionPeerError.rejected(
                "Native Usage collection is unavailable on this machine.")
        }
        guard
            let scriptURL = MachineResources.url(
                forResource: "usage-snapshot", withExtension: "py"),
            let script = try? String(contentsOf: scriptURL, encoding: .utf8)
        else { throw ExtensionPeerError.unavailable }
        return
            "command -v python3 >/dev/null 2>&1 || { printf '%s\\n' 'Install Python 3 on this saved machine to collect receipt snapshots.' >&2; exit 69; }; exec python3 -c "
            + POSIXQuote.quote(script)
    }
}
