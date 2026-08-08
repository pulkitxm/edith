import Foundation

public enum MachineRegistry {
    public struct Files: Sendable {
        public let machines: URL
        public let forwards: URL
        public let snippets: URL

        public init(
            machines: URL = MachinePaths.machinesFile,
            forwards: URL = MachinePaths.forwardsFile,
            snippets: URL = MachinePaths.snippetsFile
        ) {
            self.machines = machines
            self.forwards = forwards
            self.snippets = snippets
        }
    }

    public struct Contents: Sendable {
        public var machines: [Machine]
        public var forwards: [PortForward]
        public var snippets: [CommandSnippet]

        public init(
            machines: [Machine] = [], forwards: [PortForward] = [],
            snippets: [CommandSnippet] = []
        ) {
            self.machines = machines
            self.forwards = forwards
            self.snippets = snippets
        }
    }

    public static func load(_ files: Files = Files()) -> Contents {
        Contents(
            machines: decode(files.machines) ?? [],
            forwards: decode(files.forwards) ?? [],
            snippets: decode(files.snippets) ?? [])
    }

    public static func machines(_ files: Files = Files()) -> [Machine] {
        decode(files.machines) ?? []
    }

    public static func forwards(_ files: Files = Files()) -> [PortForward] {
        decode(files.forwards) ?? []
    }

    public static func snippets(_ files: Files = Files()) -> [CommandSnippet] {
        decode(files.snippets) ?? []
    }

    @discardableResult
    public static func add(_ machine: Machine, _ files: Files = Files()) -> [Machine] {
        var all = machines(files)
        all.append(machine)
        encode(all, to: files.machines)
        return all
    }

    @discardableResult
    public static func update(_ machine: Machine, _ files: Files = Files()) -> [Machine] {
        var all = machines(files)
        guard let index = all.firstIndex(where: { $0.id == machine.id }) else { return all }
        all[index] = machine
        encode(all, to: files.machines)
        guard files.machines == MachinePaths.machinesFile else { return all }
        if !MachineUsageStore.restamp(all).isEmpty {
            IPC.post(IPC.Name.requestUsageRefresh)
        }
        return all
    }

    @discardableResult
    public static func remove(id: UUID, _ files: Files = Files()) -> Contents {
        var contents = load(files)
        contents.machines.removeAll { $0.id == id }
        contents.forwards.removeAll { $0.machineID == id }
        contents.snippets.removeAll { $0.machineID == id }
        encode(contents.machines, to: files.machines)
        encode(contents.forwards, to: files.forwards)
        encode(contents.snippets, to: files.snippets)
        MachineSecrets.deleteAll(machineID: id)
        return contents
    }

    @discardableResult
    public static func addForward(_ forward: PortForward, _ files: Files = Files())
        -> [PortForward]
    {
        var all = forwards(files)
        all.append(forward)
        encode(all, to: files.forwards)
        return all
    }

    @discardableResult
    public static func removeForward(id: UUID, _ files: Files = Files()) -> [PortForward] {
        var all = forwards(files)
        all.removeAll { $0.id == id }
        encode(all, to: files.forwards)
        return all
    }

    @discardableResult
    public static func addSnippet(_ snippet: CommandSnippet, _ files: Files = Files())
        -> [CommandSnippet]
    {
        var all = snippets(files)
        all.append(snippet)
        encode(all, to: files.snippets)
        return all
    }

    @discardableResult
    public static func updateSnippet(_ snippet: CommandSnippet, _ files: Files = Files())
        -> [CommandSnippet]
    {
        var all = snippets(files)
        guard let index = all.firstIndex(where: { $0.id == snippet.id }) else { return all }
        all[index] = snippet
        encode(all, to: files.snippets)
        return all
    }

    @discardableResult
    public static func removeSnippet(id: UUID, _ files: Files = Files()) -> [CommandSnippet] {
        var all = snippets(files)
        all.removeAll { $0.id == id }
        encode(all, to: files.snippets)
        return all
    }

    public static func forwards(machineID: UUID, in all: [PortForward]) -> [PortForward] {
        all.filter { $0.machineID == machineID }
    }

    public static func snippets(machineID: UUID, in all: [CommandSnippet]) -> [CommandSnippet] {
        all.filter { $0.machineID == nil || $0.machineID == machineID }
    }

    private static func decode<T: Decodable>(_ file: URL) -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, to file: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
