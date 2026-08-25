import Darwin
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
        withMutationLock(files) {
            var all = machines(files)
            all.append(machine)
            encode(all, to: files.machines)
            return all
        } ?? machines(files)
    }

    @discardableResult
    public static func update(_ machine: Machine, _ files: Files = Files()) -> [Machine] {
        let mutation = withMutationLock(files) { () -> (machines: [Machine], updated: Bool) in
            var all = machines(files)
            guard let index = all.firstIndex(where: { $0.id == machine.id }) else {
                return (all, false)
            }
            all[index] = machine
            encode(all, to: files.machines)
            return (all, true)
        }
        guard let mutation else { return machines(files) }
        guard mutation.updated, files.machines == MachinePaths.machinesFile else {
            return mutation.machines
        }
        if !MachineUsageStore.restamp(mutation.machines).isEmpty {
            IPC.post(IPC.Name.requestUsageRefresh)
        }
        return mutation.machines
    }

    @discardableResult
    public static func remove(id: UUID, _ files: Files = Files()) -> Contents {
        guard
            let contents = withMutationLock(
                files,
                {
                    var contents = load(files)
                    contents.machines.removeAll { $0.id == id }
                    contents.forwards.removeAll { $0.machineID == id }
                    contents.snippets.removeAll { $0.machineID == id }
                    encode(contents.machines, to: files.machines)
                    encode(contents.forwards, to: files.forwards)
                    encode(contents.snippets, to: files.snippets)
                    return contents
                })
        else { return load(files) }
        MachineSecrets.deleteAll(machineID: id)
        return contents
    }

    @discardableResult
    public static func addForward(_ forward: PortForward, _ files: Files = Files())
        -> [PortForward]
    {
        withMutationLock(files) {
            var all = forwards(files)
            all.append(forward)
            encode(all, to: files.forwards)
            return all
        } ?? forwards(files)
    }

    @discardableResult
    public static func removeForward(id: UUID, _ files: Files = Files()) -> [PortForward] {
        withMutationLock(files) {
            var all = forwards(files)
            all.removeAll { $0.id == id }
            encode(all, to: files.forwards)
            return all
        } ?? forwards(files)
    }

    @discardableResult
    public static func addSnippet(_ snippet: CommandSnippet, _ files: Files = Files())
        -> [CommandSnippet]
    {
        withMutationLock(files) {
            var all = snippets(files)
            all.append(snippet)
            encode(all, to: files.snippets)
            return all
        } ?? snippets(files)
    }

    @discardableResult
    public static func updateSnippet(_ snippet: CommandSnippet, _ files: Files = Files())
        -> [CommandSnippet]
    {
        withMutationLock(files) {
            var all = snippets(files)
            guard let index = all.firstIndex(where: { $0.id == snippet.id }) else { return all }
            all[index] = snippet
            encode(all, to: files.snippets)
            return all
        } ?? snippets(files)
    }

    @discardableResult
    public static func removeSnippet(id: UUID, _ files: Files = Files()) -> [CommandSnippet] {
        withMutationLock(files) {
            var all = snippets(files)
            all.removeAll { $0.id == id }
            encode(all, to: files.snippets)
            return all
        } ?? snippets(files)
    }

    public static func forwards(machineID: UUID, in all: [PortForward]) -> [PortForward] {
        all.filter { $0.machineID == machineID }
    }

    public static func snippets(machineID: UUID, in all: [CommandSnippet]) -> [CommandSnippet] {
        all.filter { $0.machineID == nil || $0.machineID == machineID }
    }

    static func lockURL(_ files: Files) -> URL {
        files.machines.deletingLastPathComponent()
            .appendingPathComponent(".machine-registry.lock")
    }

    private static func withMutationLock<T>(_ files: Files, _ body: () -> T) -> T? {
        let url = lockURL(files)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(
            url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { return nil }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            return nil
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                close(descriptor)
                return nil
            }
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return body()
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
