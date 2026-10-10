import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum UsageCLIMachines {
    static func resolve(_ query: String) throws -> Machine {
        let machines = UsageCLIEnvironment.machines()
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

    static var selected: Set<UUID> {
        get {
            Set(
                (SharedDefaults.store.stringArray(forKey: UsageMachinesPeer.selectedDefaultsKey)
                    ?? [])
                    .compactMap(UUID.init(uuidString:)))
        }
        set {
            SharedDefaults.store.set(
                newValue.map(\.uuidString).sorted(), forKey: UsageMachinesPeer.selectedDefaultsKey)
        }
    }

    static func setCounted(_ included: Bool, id: UUID) {
        var ids = selected
        if included { ids.insert(id) } else { ids.remove(id) }
        selected = ids
    }

    static func summary(_ machine: Machine) throws -> MachineUsageSummary? {
        let file = Repo.dataDir.appendingPathComponent(
            "machines/" + machine.id.uuidString.lowercased() + ".json")
        guard let data = try UsageDataFiles.readRegularFile(at: file, maximumBytes: 67_108_864)
        else {
            return nil
        }
        let document = try JSONDecoder().decode(UsageDocument.self, from: data)
        let totals = UsageAnalysis.totals(document.daily, sources: nil)
        return MachineUsageSummary(
            machineID: machine.id, name: machine.name, slug: machine.id.uuidString.lowercased(),
            host: machine.host,
            collectedAt: document.generatedAt.flatMap(EdithDate.parseISO) ?? .distantPast,
            sources: document.sources ?? [], days: document.daily.count, cost: totals.cost,
            tokens: totals.tokens)
    }

    static func collect(_ targets: [Machine], once: Bool, timeout: TimeInterval, verbose: Bool)
        async throws -> MachineUsageRoundResult
    {
        guard UsageCLIEnvironment.controller != nil else {
            throw CLIFailure.unavailable("the Usage extension is off")
        }
        var result = MachineUsageRoundResult()
        for machine in targets {
            try Task.checkCancellation()
            do {
                if verbose { CLIOut.note("collecting usage from " + machine.name) }
                let collected = try await UsageCLIEnvironment.collectMachine(
                    machine, timeout, verbose)
                let data = try UsageMachinesPeer.canonicalized(collected, machine: machine)
                let directory = Repo.dataDir.appendingPathComponent("machines")
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try Task.checkCancellation()
                try UsageDataTransaction.withExclusiveAccess(dataDirectory: Repo.dataDir) {
                    try UsageDataFiles.write(
                        data,
                        to: directory.appendingPathComponent(
                            machine.id.uuidString.lowercased() + ".json"))
                }
                if !once { setCounted(true, id: machine.id) }
                if let summary = try summary(machine) { result.collected.append(summary) }
            } catch {
                try Task.checkCancellation()
                result.failures.append((machine: machine.name, reason: error.localizedDescription))
            }
        }
        return result
    }
}
