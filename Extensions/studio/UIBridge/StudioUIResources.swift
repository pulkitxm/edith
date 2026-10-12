import EdithExtensionSupport
import Foundation
#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif

struct StudioUIResource: Codable, Equatable, Sendable {
    let token: UUID
    let length: Int
}

@MainActor final class StudioUIResources {
    static let chunkBytes = 256 * 1_024
    static let maximumBytes = 1_024 * 1_024 * 1_024
    private struct Entry {
        let handle: StudioUIResource
        let url: URL
        var written: Int
        var accessed: ContinuousClock.Instant
#if EDITH_FUNCTIONAL_FIXTURE
        var fixtureFile: WorkerFixtureOutputFile?
#endif
    }
    private var entries: [UUID: Entry] = [:]
    private var directory: URL?
    private var timer: Task<Void, Never>?
    private var stopped = false
#if EDITH_FUNCTIONAL_FIXTURE
    private var fixtureAdmission: WorkerFixtureEngineAdmission?
    private var fixtureFiles: [String: WorkerFixtureOutputFile] = [:]
    private var availableFixtureFiles: [String: WorkerFixtureOutputFile] = [:]
#endif

    deinit {
        timer?.cancel()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

#if EDITH_FUNCTIONAL_FIXTURE
    func configureFixture(_ admission: WorkerFixtureEngineAdmission) throws {
        try admission.requireCurrent()
        guard admission.descriptor.owner == "studio", admission.descriptor.role == "app",
            directory == nil, entries.isEmpty, fixtureAdmission == nil, fixtureFiles.isEmpty, !stopped
        else { throw WorkerFixtureError.invalid }
        fixtureAdmission = admission
    }

#endif
    func store(_ data: Data) throws -> StudioUIResource {
        let handle = try create(length: data.count)
        do {
            let entry = try lookup(handle)
#if EDITH_FUNCTIONAL_FIXTURE
            if let file = entry.fixtureFile {
                try file.write(data, offset: 0)
            } else {
                try data.write(to: entry.url, options: .atomic)
            }
#else
            try data.write(to: entry.url, options: .atomic)
#endif
            entries[handle.token]?.written = data.count
            return handle
        } catch { remove(handle); throw error }
    }

    func consume(_ handle: StudioUIResource) throws -> Data {
        let entry = try lookup(handle)
        guard entry.written == handle.length else { throw ExtensionPeerError.invalidRequest }
        defer { remove(handle) }
#if EDITH_FUNCTIONAL_FIXTURE
        if let file = entry.fixtureFile { return try file.read(offset: 0, count: handle.length) }
#endif
        return try Data(contentsOf: entry.url, options: .mappedIfSafe)
    }

    func invoke(_ operation: String, payload: Data) throws -> Data {
        guard !stopped, payload.count <= StudioCommands.maximumRequestBytes,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        let fields: Set<String>
        switch operation {
        case "studio.ui.blob.create": fields = ["length"]
        case "studio.ui.blob.read": fields = ["handle", "offset"]
        case "studio.ui.blob.write": fields = ["handle", "offset", "data"]
        case "studio.ui.blob.end": fields = ["handle"]
        default: throw ExtensionPeerError.invalidRequest
        }
        guard Set(object.keys) == fields else { throw ExtensionPeerError.invalidRequest }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        if operation == "studio.ui.blob.create" {
            guard let length = object["length"] as? Int else {
                throw ExtensionPeerError.invalidRequest
            }
            return try encoder.encode(create(length: length))
        }
        guard let value = object["handle"] else { throw ExtensionPeerError.invalidRequest }
        let handle = try JSONDecoder().decode(
            StudioUIResource.self,
            from: JSONSerialization.data(withJSONObject: value))
        var entry = try lookup(handle)
        if operation == "studio.ui.blob.end" { remove(handle); return Data("{}".utf8) }
        guard let offset = object["offset"] as? Int, (0...handle.length).contains(offset) else {
            throw ExtensionPeerError.invalidRequest
        }
        entry.accessed = .now
        entries[handle.token] = entry
        if operation == "studio.ui.blob.read" {
            guard entry.written == handle.length else { throw ExtensionPeerError.invalidRequest }
#if EDITH_FUNCTIONAL_FIXTURE
            if let file = entry.fixtureFile {
                return try encoder.encode(
                    file.read(offset: offset, count: min(Self.chunkBytes, handle.length - offset)))
            }
#endif
            let file = try FileHandle(forReadingFrom: entry.url)
            defer { try? file.close() }
            try file.seek(toOffset: UInt64(offset))
            let data =
                try file.read(upToCount: min(Self.chunkBytes, handle.length - offset)) ?? Data()
            return try encoder.encode(data)
        }
        guard let text = object["data"] as? String, let data = Data(base64Encoded: text),
            data.count <= Self.chunkBytes, !data.isEmpty, offset == entry.written,
            data.count <= handle.length - offset
        else { throw ExtensionPeerError.invalidRequest }
#if EDITH_FUNCTIONAL_FIXTURE
        if let file = entry.fixtureFile {
            try file.write(data, offset: offset)
            entry.written += data.count
            entries[handle.token] = entry
            return Data("{}".utf8)
        }
#endif
        let file = try FileHandle(forWritingTo: entry.url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        try file.write(contentsOf: data)
        entry.written += data.count
        entries[handle.token] = entry
        return Data("{}".utf8)
    }

    func suspend() {
        stopped = true
        timer?.cancel()
    }

    func suspendAndWait() async {
        suspend()
        let owned = timer
        await owned?.value
        timer = nil
    }

    func shutdownAndWait() async {
        await suspendAndWait()
        shutdown()
    }

    func shutdown() {
        stopped = true
        timer?.cancel()
        for entry in Array(entries.values) { remove(entry.handle) }
        entries.removeAll()
#if EDITH_FUNCTIONAL_FIXTURE
        for file in fixtureFiles.values { file.close() }
        fixtureFiles.removeAll()
        availableFixtureFiles.removeAll()
#endif
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func create(length: Int) throws -> StudioUIResource {
#if EDITH_FUNCTIONAL_FIXTURE
        try fixtureAdmission?.requireCurrent()
#endif
        expire()
        guard !stopped, (0...Self.maximumBytes).contains(length), entries.count < 8,
            entries.values.reduce(0, { $0 + $1.handle.length }) <= Self.maximumBytes * 2 - length
        else { throw ExtensionPeerError.rejected("The Studio media transfer is full.") }
        let handle = StudioUIResource(token: UUID(), length: length)
        let url: URL
#if EDITH_FUNCTIONAL_FIXTURE
        let fixtureFile: WorkerFixtureOutputFile?
        if let admission = fixtureAdmission {
            let occupied = Set(entries.values.map { $0.url.path })
            let names = Set((0..<8).map { "studio.ui.blob.\($0)" })
            guard let output = admission.descriptor.outputs.first(where: {
                names.contains($0.name) && !occupied.contains($0.path)
            }) else { throw ExtensionPeerError.unavailable }
            url = try admission.outputURL(named: output.name)
            if let available = availableFixtureFiles.removeValue(forKey: output.name) {
                try available.requireCurrent()
                fixtureFile = available
            } else {
                let owned = try admission.createOutputFile(named: output.name)
                fixtureFiles[output.name] = owned
                fixtureFile = owned
            }
        } else {
            fixtureFile = nil
            url = try temporaryURL(for: handle)
        }
#else
        url = try temporaryURL(for: handle)
#endif
#if EDITH_FUNCTIONAL_FIXTURE
        if fixtureFile == nil { try createTemporaryFile(at: url) }
#else
        try createTemporaryFile(at: url)
#endif
        var entry = Entry(handle: handle, url: url, written: 0, accessed: .now)
#if EDITH_FUNCTIONAL_FIXTURE
        entry.fixtureFile = fixtureFile
#endif
        entries[handle.token] = entry
        if timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self, !self.stopped else { return }
                    self.expire()
                }
            }
        }
        return handle
    }

    private func createTemporaryFile(at url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        else { throw ExtensionPeerError.unavailable }
    }

    private func temporaryURL(for handle: StudioUIResource) throws -> URL {
        if directory == nil {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "studio-ui-resources-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            directory = root
        }
        guard let directory else { throw ExtensionPeerError.unavailable }
        return directory.appendingPathComponent(handle.token.uuidString)
    }

    private func lookup(_ handle: StudioUIResource) throws -> Entry {
#if EDITH_FUNCTIONAL_FIXTURE
        try fixtureAdmission?.requireCurrent()
#endif
        expire()
        guard !stopped, let entry = entries[handle.token], entry.handle == handle else {
            throw ExtensionPeerError.invalidRequest
        }
#if EDITH_FUNCTIONAL_FIXTURE
        if fixtureAdmission != nil {
            guard let file = entry.fixtureFile else { throw WorkerFixtureError.invalid }
            try file.requireCurrent()
        }
#endif
        return entry
    }

    private func remove(_ handle: StudioUIResource) {
        guard let entry = entries.removeValue(forKey: handle.token) else { return }
#if EDITH_FUNCTIONAL_FIXTURE
        if fixtureAdmission != nil {
            if let file = entry.fixtureFile { availableFixtureFiles[file.name] = file }
            return
        }
#endif
        try? FileManager.default.removeItem(at: entry.url)
    }

    private func expire() {
        for entry in entries.values where entry.accessed.duration(to: .now) >= .seconds(60) {
            remove(entry.handle)
        }
    }
}
