import EdithKit
import Foundation

public enum MachineDirectory {
    public static func load(from file: URL = MachinePaths.machinesFile) -> [Machine] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Machine].self, from: data)) ?? []
    }

    public static func names(from machines: [Machine]) -> [String] {
        var out: [String] = []
        for machine in machines {
            out.append(machine.name)
            if case let .sshConfigAlias(alias) = machine.source, alias != machine.name {
                out.append(alias)
            }
        }
        return out
    }

    public static func resolve(_ query: String, in machines: [Machine]) throws -> Machine {
        guard !machines.isEmpty else {
            throw CLIFailure.notFound(
                "no machines are configured",
                hint: "run `ed machines add <name> <host>`, or add one in Edith under Machines")
        }
        let needle = query.lowercased()
        if let exact = machines.first(where: { $0.name.lowercased() == needle }) { return exact }
        if let byAlias = machines.first(where: { machine in
            guard case let .sshConfigAlias(alias) = machine.source else { return false }
            return alias.lowercased() == needle
        }) {
            return byAlias
        }
        if let byID = machines.first(where: { $0.id.uuidString.lowercased() == needle }) {
            return byID
        }
        let prefixed = machines.filter { machine in
            if machine.name.lowercased().hasPrefix(needle) { return true }
            if case let .sshConfigAlias(alias) = machine.source {
                return alias.lowercased().hasPrefix(needle)
            }
            return false
        }
        if prefixed.count == 1, let only = prefixed.first { return only }
        if prefixed.count > 1 {
            throw CLIFailure.notFound(
                "\(query) matches more than one machine",
                hint: prefixed.map(\.name).joined(separator: ", "))
        }
        throw CLIFailure.notFound(
            "no machine named \(query)",
            hint: "known machines: " + machines.map(\.name).joined(separator: ", "))
    }

    public static func isKnown(_ query: String, in machines: [Machine]) -> Bool {
        (try? resolve(query, in: machines)) != nil
    }

    public static func summary(_ machine: Machine) -> JSONValue {
        var source = "manual"
        var alias = JSONValue.null
        if case let .sshConfigAlias(value) = machine.source {
            source = "sshConfigAlias"
            alias = .string(value)
        }
        return .object([
            "id": .string(machine.id.uuidString),
            "name": .string(machine.name),
            "host": .string(machine.host),
            "port": .int(machine.port),
            "username": .string(machine.username),
            "auth": .string(machine.auth.displayName),
            "source": .string(source),
            "sshAlias": alias,
            "sshTarget": .string(machine.sshTarget),
            "wakeMACAddress": .optional(machine.wakeMACAddress),
            "createdAt": .date(machine.createdAt),
            "controlSocket": .string(MachinePaths.socketFile(for: machine.id).path),
            "connected": .bool(hasLiveControlSocket(machine)),
        ])
    }

    public static func hasLiveControlSocket(_ machine: Machine) -> Bool {
        let socket = MachinePaths.socketFile(for: machine.id).path
        guard FileManager.default.fileExists(atPath: socket) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-S", socket, "-O", "check", machine.sshTarget]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
