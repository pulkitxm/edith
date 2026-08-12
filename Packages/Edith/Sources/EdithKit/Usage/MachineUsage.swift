import Foundation

public struct MachineUsageSummary: Equatable, Sendable, Identifiable {
    public var machineID: UUID
    public var name: String
    public var slug: String
    public var host: String
    public var collectedAt: Date
    public var sources: [String]
    public var days: Int
    public var cost: Double
    public var tokens: Double

    public var id: UUID { machineID }

    public init(
        machineID: UUID, name: String, slug: String, host: String, collectedAt: Date,
        sources: [String], days: Int, cost: Double, tokens: Double
    ) {
        self.machineID = machineID
        self.name = name
        self.slug = slug
        self.host = host
        self.collectedAt = collectedAt
        self.sources = sources
        self.days = days
        self.cost = cost
        self.tokens = tokens
    }
}

public struct MachineUsageFreshness: Equatable, Sendable {
    public static let tolerance: TimeInterval = 5 * 60

    public let collectedAt: Date
    public let age: TimeInterval
    public let isStale: Bool

    public init(
        collectedAt: Date, now: Date = Date(),
        refreshInterval: TimeInterval = MachineUsageRound.interval,
        tolerance: TimeInterval = Self.tolerance
    ) {
        self.collectedAt = collectedAt
        age = max(0, now.timeIntervalSince(collectedAt))
        isStale = age > refreshInterval + tolerance
    }

    public var ageLabel: String {
        let minutes = Int(age) / 60
        if minutes == 0 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return remainingMinutes == 0
                ? "\(hours)h ago"
                : "\(hours)h \(remainingMinutes)m ago"
        }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0
            ? "\(days)d ago"
            : "\(days)d \(remainingHours)h ago"
    }

    public var statusLabel: String {
        isStale ? "stale · collected \(ageLabel)" : "collected \(ageLabel)"
    }
}

public enum MachineUsageError: LocalizedError, Equatable {
    case scriptMissing
    case unreachableHome(String)
    case noUsageThere(String)
    case collectorFailed(machine: String, status: Int32, detail: String)
    case documentUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .scriptMissing:
            return "the usage collector is missing from this build"
        case let .unreachableHome(name):
            return "\(name) did not say where its home directory is"
        case let .noUsageThere(name):
            return "no agent usage on \(name) yet"
        case let .collectorFailed(name, status, detail):
            let tail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty
                ? "the collector exited \(status) on \(name)"
                : "the collector exited \(status) on \(name): \(tail)"
        case let .documentUnreadable(name):
            return "\(name) produced a usage file this build cannot read"
        }
    }
}

public enum MachineUsageSlug {
    public static func slug(for name: String) -> String {
        var out = ""
        var lastWasDash = false
        for character in name.lowercased() {
            if character.isLetter || character.isNumber, character.isASCII {
                out.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "machine" : out
    }

    public static func slugs(for machines: [Machine]) -> [UUID: String] {
        var byBase: [String: [Machine]] = [:]
        for machine in machines {
            byBase[slug(for: machine.name), default: []].append(machine)
        }
        var out: [UUID: String] = [:]
        for (base, sharing) in byBase {
            guard sharing.count > 1 else {
                if let only = sharing.first { out[only.id] = base }
                continue
            }
            for machine in sharing {
                out[machine.id] = base + "-" + machine.id.uuidString.prefix(4).lowercased()
            }
        }
        return out
    }
}

public enum MachineUsageSourceIdentity {
    public static func canonical(machineID: String, source: String) -> String? {
        let machine = machineID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base =
            source.split(separator: ":", omittingEmptySubsequences: false).last?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !machine.isEmpty, !base.isEmpty else { return nil }
        return "machine:\(machine):\(base)"
    }
}

public enum MachineUsageSelection {
    public static let key = "usageMachines"

    public static func machineIDs(_ store: UserDefaults = SharedDefaults.store) -> Set<UUID> {
        let stored = store.stringArray(forKey: key) ?? []
        return Set(stored.compactMap(UUID.init(uuidString:)))
    }

    public static func includes(_ machineID: UUID, _ store: UserDefaults = SharedDefaults.store)
        -> Bool
    {
        machineIDs(store).contains(machineID)
    }

    public static func include(_ machineID: UUID, _ store: UserDefaults = SharedDefaults.store) {
        save(machineIDs(store).union([machineID]), store)
    }

    public static func exclude(_ machineID: UUID, _ store: UserDefaults = SharedDefaults.store) {
        save(machineIDs(store).subtracting([machineID]), store)
    }

    public static func included(
        in machines: [Machine], _ store: UserDefaults = SharedDefaults.store
    ) -> [Machine] {
        let chosen = machineIDs(store)
        return machines.filter { chosen.contains($0.id) }
    }

    private static func save(_ ids: Set<UUID>, _ store: UserDefaults) {
        store.set(ids.map(\.uuidString).sorted(), forKey: key)
    }
}

public enum MachineUsageStore {
    private struct StoredDocument: Decodable {
        struct MachineBlock: Decodable {
            let id: String?
            let name: String?
            let slug: String?
            let host: String?
            let collectedAt: String?
        }
        struct Totals: Decodable {
            let cost: Double?
            let tokens: Double?
        }
        struct Day: Decodable {
            let period: String
        }
        let machine: MachineBlock?
        let sources: [String]?
        let totals: Totals?
        let daily: [Day]?
    }

    public static func summaries(in directory: URL = UsageCollector.machinesDirectory)
        -> [MachineUsageSummary]
    {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        let files: [URL] = (contents ?? []).filter { $0.pathExtension == "json" }
        let found: [MachineUsageSummary] = files.compactMap { summary(at: $0) }
        return found.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func summary(
        machineID: UUID, in directory: URL = UsageCollector.machinesDirectory
    ) -> MachineUsageSummary? {
        summary(at: UsageCollector.machineFile(id: machineID, in: directory))
    }

    public static func summary(at url: URL) -> MachineUsageSummary? {
        guard let data = try? Data(contentsOf: url),
            let document = try? JSONDecoder().decode(StoredDocument.self, from: data),
            let block = document.machine,
            let id = block.id.flatMap(UUID.init(uuidString:))
        else { return nil }
        let name = block.name ?? id.uuidString
        return MachineUsageSummary(
            machineID: id,
            name: name,
            slug: block.slug ?? MachineUsageSlug.slug(for: name),
            host: block.host ?? "",
            collectedAt: EdithDate.parseISO(block.collectedAt) ?? .distantPast,
            sources: document.sources ?? [],
            days: document.daily?.count ?? 0,
            cost: document.totals?.cost ?? 0,
            tokens: document.totals?.tokens ?? 0)
    }

    @discardableResult
    public static func save(
        document: Data, machine: Machine, slug: String, host: String, collectedAt: Date,
        in directory: URL = UsageCollector.machinesDirectory
    ) throws -> MachineUsageSummary {
        guard var object = try? JSONSerialization.jsonObject(with: document) as? [String: Any],
            object["daily"] is [Any]
        else { throw MachineUsageError.documentUnreadable(machine.name) }
        object["machine"] = [
            "id": machine.id.uuidString,
            "name": machine.name,
            "slug": slug,
            "host": host,
            "collectedAt": EdithDate.isoString(collectedAt),
        ]
        let encoded = try JSONSerialization.data(withJSONObject: object)
        let file = UsageCollector.machineFile(id: machine.id, in: directory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try encoded.write(to: file, options: .atomic)
        guard let summary = summary(at: file) else {
            throw MachineUsageError.documentUnreadable(machine.name)
        }
        return summary
    }

    public static func prune(
        keeping machineIDs: [UUID], in directory: URL = UsageCollector.machinesDirectory
    ) {
        let known = Set(machineIDs)
        for id in storedIDs(in: directory) where !known.contains(id) {
            forget(machineID: id, in: directory)
        }
    }

    @discardableResult
    public static func restamp(
        _ machines: [Machine], in directory: URL = UsageCollector.machinesDirectory
    ) -> [UUID] {
        let slugs = MachineUsageSlug.slugs(for: machines)
        let byID = Dictionary(machines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: [UUID] = []
        for id in storedIDs(in: directory) {
            guard let machine = byID[id], let slug = slugs[id] else { continue }
            let file = UsageCollector.machineFile(id: id, in: directory)
            guard let data = try? Data(contentsOf: file),
                var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                var block = object["machine"] as? [String: Any]
            else { continue }
            guard block["name"] as? String != machine.name || block["slug"] as? String != slug
            else { continue }
            block["name"] = machine.name
            block["slug"] = slug
            object["machine"] = block
            guard let encoded = try? JSONSerialization.data(withJSONObject: object) else {
                continue
            }
            try? encoded.write(to: file, options: .atomic)
            changed.append(id)
        }
        return changed
    }

    public static func storedIDs(in directory: URL = UsageCollector.machinesDirectory) -> [UUID] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        let names = (contents ?? []).filter { $0.pathExtension == "json" }
        return names.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
    }

    @discardableResult
    public static func forget(
        machineID: UUID, in directory: URL = UsageCollector.machinesDirectory
    ) -> Bool {
        let file = UsageCollector.machineFile(id: machineID, in: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        try? FileManager.default.removeItem(at: file)
        return true
    }
}

public struct MachineUsageCollection: Sendable {
    public let summary: MachineUsageSummary
    public let log: String

    public init(summary: MachineUsageSummary, log: String) {
        self.summary = summary
        self.log = log
    }
}

public enum MachineUsageCollector {
    public static let defaultTimeout: TimeInterval = 900
    public static let nothingToCollect: Int32 = 3

    public static let probeCommand = "printf '%s\\n%s\\n' \"$HOME\" \"$(uname -n 2>/dev/null)\""

    public static func outputDirectory(home: String) -> String {
        "\(home)/.cache/edith/usage"
    }

    public static func runCommand(home: String) -> String {
        "bash -s -- \(ShellQuote.quote(outputDirectory(home: home)))"
    }

    public static func documentPath(home: String) -> String {
        "\(outputDirectory(home: home))/usage.json"
    }

    public static func collect(
        machine: Machine, slug: String, over connection: SSHConnection,
        timeout: TimeInterval = defaultTimeout, now: Date = Date()
    ) async throws -> MachineUsageCollection {
        guard let script = UsageCollector.script() else { throw MachineUsageError.scriptMissing }
        let probe = try await connection.run(probeCommand, timeout: 30)
        let lines = probe.stdoutText.split(separator: "\n", omittingEmptySubsequences: false)
        let home = lines.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard probe.succeeded, !home.isEmpty, home.hasPrefix("/") else {
            throw MachineUsageError.unreachableHome(machine.name)
        }
        let reported = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespaces) : ""
        let host = reported.isEmpty ? machine.host : reported

        let run = try await connection.run(
            runCommand(home: home), stdin: script, timeout: timeout)
        guard run.status != nothingToCollect else {
            throw MachineUsageError.noUsageThere(machine.name)
        }
        guard run.succeeded else {
            throw MachineUsageError.collectorFailed(
                machine: machine.name, status: run.status,
                detail: lastLine(of: run.combinedText))
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-usage-\(machine.id.uuidString).json")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await connection.download(remotePath: documentPath(home: home), to: scratch)
        let document = try Data(contentsOf: scratch)
        let summary = try MachineUsageStore.save(
            document: document, machine: machine, slug: slug, host: host, collectedAt: now)
        return MachineUsageCollection(summary: summary, log: run.combinedText)
    }

    public static let transportFailure: Int32 = 255

    public static func lastLine(of output: String) -> String {
        let lines =
            output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return "" }
        return spoken(last)
    }

    public static func spoken(_ line: String) -> String {
        guard let event = UsageRefreshEvent.parse(line) else { return line }
        switch event {
        case let .phase(name, detail, _): return "\(name): \(detail)"
        case let .note(text): return text
        case let .summary(label, value): return "\(label) \(value)"
        case let .failure(text): return text
        case let .finished(seconds): return "finished in \(String(format: "%.2f", seconds))s"
        }
    }
}
