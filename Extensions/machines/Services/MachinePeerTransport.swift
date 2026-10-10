import EdithExtensionSupport
import Foundation

@MainActor public final class MachinePeerTransport {
    private var connections: [UUID: SSHConnection] = [:]
    private var connectionJobs: [UUID: Task<SSHConnection, Error>] = [:]
    private var forwards: [Int: PortForward] = [:]
    private var stopped = false

    public typealias UsagePlatform =
        @MainActor @Sendable (Machine) async throws -> RemoteMachinePlatform
    public typealias UsageRun =
        @MainActor @Sendable (Machine, String, Data, TimeInterval, Int) async throws ->
        SSHExecResult
    public typealias UsageInvoke =
        @MainActor @Sendable (String, Data, TimeInterval) async throws -> Data
    private let usagePlatform: UsagePlatform?
    private let usageRun: UsageRun?
    private let usageInvoke: UsageInvoke?
    public let snapshots: MachineUsageSnapshotStore

    public init(
        files: MachineRegistry.Files = .init(), usagePlatform: UsagePlatform? = nil,
        usageRun: UsageRun? = nil, usageInvoke: UsageInvoke? = nil
    ) {
        snapshots = MachineUsageSnapshotStore(files: files)
        self.usagePlatform = usagePlatform; self.usageRun = usageRun; self.usageInvoke = usageInvoke
    }

    public func prepareConnection(_ machine: Machine) async throws -> MachineConnectionRecipe {
        guard MachineConnectionRecipe.valid(machine), !stopped else {
            throw ExtensionPeerError.invalidRequest
        }
        let connection = try await connected(machine)
        try Task.checkCancellation()
        guard !stopped, connections[machine.id] === connection,
            await connection.masterIsAlive(), let platform = await connection.remotePlatform
        else {
            throw ExtensionPeerError.unavailable
        }
        try Task.checkCancellation()
        guard !stopped, connections[machine.id] === connection else {
            throw ExtensionPeerError.unavailable
        }
        return try MachineConnectionRecipe(
            machine: machine,
            sshArguments: MachineConnectionRecipe.masterOnlyOptions
                + connection.terminalArguments(),
            controlPath: connection.controlSocketPath, platform: platform)
    }

    public func run(_ machine: Machine, command: String, stdin: Data?, timeout: TimeInterval)
        async throws -> String
    {
        let connection = try await connected(machine)
        let result = try await connection.run(
            command, stdin: stdin, timeout: timeout, maximumOutputBytes: 6 * 1_024 * 1_024)
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
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
        guard !stopped else { throw ExtensionPeerError.unavailable }
        let invoke: UsageInvoke
        if let usageInvoke {
            invoke = usageInvoke
        } else {
            guard let endpoint = ExtensionPeerEndpoint.current(owner: "usage") else {
                throw ExtensionPeerError.rejected(
                    "Enable Usage to collect receipts from saved machines.")
            }
            invoke = { command, payload, timeout in
                try await endpoint.invoke(command, payload: payload, timeout: timeout)
            }
        }
        let connection: SSHConnection?
        let platform: RemoteMachinePlatform
        if let usagePlatform {
            platform = try await usagePlatform(machine); connection = nil
        } else {
            connection = try await connected(machine)
            guard let detected = await connection?.remotePlatform else {
                throw ExtensionPeerError.unavailable
            }
            platform = detected
        }
        let command = try MachineRemoteUsageOperation.command(platform: platform, force: force)
        let input = try MachineRemoteUsageOperation.input()
        let progress = MachineUsageProgressContext.output
        let result: SSHExecResult
        if let usageRun {
            result = try await usageRun(
                machine, command, input, 900, MachineUsageCollectionService.maximumDocumentBytes)
        } else {
            guard let connection else { throw ExtensionPeerError.unavailable }
            result = try await connection.run(
                command, stdin: input, timeout: 900,
                maximumOutputBytes: MachineUsageCollectionService.maximumDocumentBytes,
                onStandardErrorLine: progress.map { output in { line in output(line, true) } })
        }
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
        var collectionID = snapshot.collectionID
        do {
            let projected = try await invoke(
                "usage.machines.project", JSONEncoder().encode(snapshot), 900)
            let descriptor = try MachineCommandPayload.decode(
                Projected.self, data: projected,
                required: ["collectionID", "byteCount", "sha256", "generatedAt"])
            collectionID = descriptor.collectionID
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            guard descriptor.byteCount > 0,
                descriptor.byteCount <= MachineUsageCollectionService.maximumDocumentBytes,
                descriptor.sha256.count == 64,
                descriptor.sha256.utf8.allSatisfy({
                    (48...57).contains($0) || (97...102).contains($0)
                }),
                ISO8601DateFormatter().date(from: descriptor.generatedAt) != nil
            else { throw ExtensionPeerError.invalidRequest }
            var document = Data()
            while document.count < descriptor.byteCount {
                try Task.checkCancellation()
                let request = ResultRequest(
                    collectionID: descriptor.collectionID, offset: document.count,
                    maximumBytes: MachineUsageCollectionService.maximumChunkBytes)
                let response = try await invoke(
                    "usage.machines.result", JSONEncoder().encode(request), 60)
                try Task.checkCancellation()
                guard !stopped else { throw ExtensionPeerError.unavailable }
                let chunk = try MachineCommandPayload.decode(
                    Chunk.self, data: response,
                    required: ["offset", "data", "finished"])
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
            await cancelProjection(invoke, id: collectionID)
            return document
        } catch {
            await cancelProjection(invoke, id: collectionID)
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
    private func cancelProjection(_ invoke: @escaping UsageInvoke, id: UUID) async {
        let payload = Data("{\"collectionID\":\"\(id.uuidString)\"}".utf8)
        await Task.detached {
            _ = try? await invoke("usage.machines.cancel", payload, 15)
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
    public static func input() throws -> Data {
        guard let url = MachineResources.url(forResource: "usage-snapshot", withExtension: "py")
        else {
            throw ExtensionPeerError.unavailable
        }
        return try Data(contentsOf: url)
    }

    public static func shellScript(platform: RemoteMachinePlatform) -> String {
        let prepare =
            platform == .windows
            ? """
            export EDITH_USAGE_SNAPSHOT_WINDOWS=1 PYTHONUTF8=1
            command -v cygpath >/dev/null 2>&1 || { printf '%s\\n' 'Git Bash cygpath is required to locate Windows receipts.' >&2; exit 69; }
            nativeHome=$(cygpath -aw "$HOME") || { printf '%s\\n' 'Git Bash could not resolve the Windows receipt home.' >&2; exit 69; }
            [ -n "$nativeHome" ] || exit 69
            export EDITH_USAGE_SNAPSHOT_HOME="$nativeHome"
            """ : ""
        return prepare + "\n" + """
            python=()
            probe='import sys,sqlite3; sys.exit(0 if sys.version_info >= (3,8) else 1)'
            if command -v python3 >/dev/null 2>&1 && python3 -c "$probe" >/dev/null 2>&1; then
                python=(python3)
            elif command -v python >/dev/null 2>&1 && python -c "$probe" >/dev/null 2>&1; then
                python=(python)
            elif command -v py >/dev/null 2>&1 && py -3 -c "$probe" >/dev/null 2>&1; then
                python=(py -3)
            else
                printf '%s\\n' 'Install Python 3.8 or newer with sqlite3 support on this saved machine, and add it to the Git Bash PATH.' >&2
                exit 69
            fi
            exec "${python[@]}" -
            """
    }

    public static func command(platform: RemoteMachinePlatform, force: Bool) throws -> String {
        let shell = shellScript(platform: platform)
        guard platform == .windows else { return "bash -lc " + POSIXQuote.quote(shell) }
        return PowerShell.command(
            """
            $gitCandidates = @(
                (Join-Path $env:ProgramFiles 'Git/bin/bash.exe'),
                (Join-Path $env:LOCALAPPDATA 'Programs/Git/bin/bash.exe')
            )
            $gitBash = $gitCandidates | Where-Object {
                Test-Path -LiteralPath $_ -PathType Leaf
            } | Select-Object -First 1
            if ($null -eq $gitBash) {
                [Console]::Error.Write('Git Bash is required to collect receipt snapshots on Windows.')
                exit 69
            }
            & $gitBash -lc \(PowerShell.literal(shell))
            exit $LASTEXITCODE
            """)
    }
}
