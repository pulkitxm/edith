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
    }
    private var entries: [UUID: Entry] = [:]
    private var directory: URL?
    private var timer: Task<Void, Never>?
    private var stopped = false
    private var fixtureAdmission: WorkerFixtureEngineAdmission?

    deinit {
        timer?.cancel()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func configureFixture(_ admission: WorkerFixtureEngineAdmission) throws {
        try admission.requireCurrent()
        guard admission.descriptor.owner == "studio", admission.descriptor.role == "app",
            directory == nil, entries.isEmpty, !stopped
        else { throw WorkerFixtureError.invalid }
        fixtureAdmission = admission
    }

    func store(_ data: Data) throws -> StudioUIResource {
        let handle = try create(length: data.count)
        do {
            try data.write(to: try lookup(handle).url, options: .atomic)
            entries[handle.token]?.written = data.count
            return handle
        } catch { remove(handle); throw error }
    }

    func consume(_ handle: StudioUIResource) throws -> Data {
        let entry = try lookup(handle)
        guard entry.written == handle.length else { throw ExtensionPeerError.invalidRequest }
        defer { remove(handle) }
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
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func create(length: Int) throws -> StudioUIResource {
        try fixtureAdmission?.requireCurrent()
        expire()
        guard !stopped, (0...Self.maximumBytes).contains(length), entries.count < 8,
            entries.values.reduce(0, { $0 + $1.handle.length }) <= Self.maximumBytes * 2 - length
        else { throw ExtensionPeerError.rejected("The Studio media transfer is full.") }
        let handle = StudioUIResource(token: UUID(), length: length)
        let url: URL
        if let admission = fixtureAdmission {
            let occupied = Set(entries.values.map { $0.url.path })
            let names = Set((0..<8).map { "studio.ui.blob.\($0)" })
            guard let output = admission.descriptor.outputs.first(where: {
                names.contains($0.name) && !occupied.contains($0.path)
            }) else { throw ExtensionPeerError.unavailable }
            url = try admission.outputURL(named: output.name)
        } else {
            if directory == nil {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "studio-ui-resources-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                directory = root
            }
            guard let directory else { throw ExtensionPeerError.unavailable }
            url = directory.appendingPathComponent(handle.token.uuidString)
        }
        guard FileManager.default.createFile(
            atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        else { throw ExtensionPeerError.unavailable }
        try fixtureAdmission?.requireOutput(url)
        entries[handle.token] = Entry(handle: handle, url: url, written: 0, accessed: .now)
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

    private func lookup(_ handle: StudioUIResource) throws -> Entry {
        try fixtureAdmission?.requireCurrent()
        expire()
        guard !stopped, let entry = entries[handle.token], entry.handle == handle else {
            throw ExtensionPeerError.invalidRequest
        }
        try fixtureAdmission?.requireOutput(entry.url)
        return entry
    }

    private func remove(_ handle: StudioUIResource) {
        guard let entry = entries.removeValue(forKey: handle.token) else { return }
        if let admission = fixtureAdmission {
            guard (try? admission.requireOutput(entry.url)) != nil else { return }
        }
        try? FileManager.default.removeItem(at: entry.url)
    }

    private func expire() {
        for entry in entries.values where entry.accessed.duration(to: .now) >= .seconds(60) {
            remove(entry.handle)
        }
    }
}
