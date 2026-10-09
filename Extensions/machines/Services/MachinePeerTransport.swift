import EdithExtensionSupport
import Foundation

@MainActor public final class MachinePeerTransport {
    private var connections: [UUID: SSHConnection] = [:]
    private var connectionJobs: [UUID: Task<SSHConnection, Error>] = [:]
    private var forwards: [Int: PortForward] = [:]
    private var stopped = false

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
        let command = try MachineRemoteUsageOperation.command(platform: platform, force: force)
        let result = try await connection.run(
            command, timeout: 900,
            maximumOutputBytes: MachineUsageCollectionService.maximumDocumentBytes)
        try Task.checkCancellation()
        guard result.succeeded else { throw ExtensionPeerError.rejected(result.stderrText) }
        return result.stdout
    }

    public func shutdown() async {
        stopped = true
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
        let directory =
            platform == .darwin
            ? "$HOME/Library/Application Support/Edith/Data/usage/data"
            : "$HOME/.cache/edith/usage"
        let refresh = force ? "1" : "0"
        return """
            set -eu
            output="\(directory)/usage.json"
            if [ \(refresh) = 1 ] || [ ! -f "$output" ]; then
                command -v ed >/dev/null 2>&1 || { printf '%s\\n' 'Enable native Usage collection on the saved machine.' >&2; exit 69; }
                EDITH_USAGE_CLOUD=0 ed usage refresh --no-machines --json >/dev/null
            fi
            [ -f "$output" ] && [ ! -L "$output" ] || { printf '%s\\n' 'The machine has no native Usage result.' >&2; exit 66; }
            size=$(wc -c < "$output" | tr -d ' ')
            [ "$size" -le 67108864 ] || exit 65
            cat "$output"
            """
    }
}
