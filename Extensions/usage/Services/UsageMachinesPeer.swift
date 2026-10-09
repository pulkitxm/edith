import CryptoKit
import Darwin
import EdithExtensionSupport
import Foundation

struct UsageMachinesPeer: Sendable {
    struct Receipt: Codable, Sendable {
        let collectionID: UUID
        let byteCount: Int
        let sha256: String
        let generatedAt: String
    }
    struct Chunk: Codable, Sendable { let offset: Int; let data: Data; let finished: Bool }
    private struct Collect: Encodable { let machineID: UUID; let force: Bool }
    private struct Result: Encodable {
        let collectionID: UUID; let offset: Int; let maximumBytes: Int
    }
    private struct Cancel: Encodable { let collectionID: UUID }
    let active: @Sendable () async -> Bool
    let invoke: @Sendable (String, Data) async throws -> Data

    func collect(machineID: UUID, force: Bool) async throws -> Data {
        try Task.checkCancellation()
        guard await active() else { throw ExtensionPeerError.unavailable }
        let reply = try await invoke(
            "machines.usage.collect",
            JSONEncoder().encode(Collect(machineID: machineID, force: force)))
        guard reply.count <= 16_384 else { throw ExtensionPeerError.invalidRequest }
        let receipt = try JSONDecoder().decode(Receipt.self, from: reply)
        do {
            guard (1...67_108_864).contains(receipt.byteCount), receipt.sha256.utf8.count == 64,
                receipt.sha256.allSatisfy({ $0.isHexDigit }),
                ISO8601DateFormatter().date(from: receipt.generatedAt) != nil
            else { throw ExtensionPeerError.invalidRequest }
            var result = Data(); result.reserveCapacity(receipt.byteCount)
            while result.count < receipt.byteCount {
                try Task.checkCancellation()
                guard await active() else { throw ExtensionPeerError.unavailable }
                let raw = try await invoke(
                    "machines.usage.result",
                    JSONEncoder().encode(
                        Result(
                            collectionID: receipt.collectionID, offset: result.count,
                            maximumBytes: 262_144)))
                guard raw.count <= 400_000 else { throw ExtensionPeerError.invalidRequest }
                let chunk = try JSONDecoder().decode(Chunk.self, from: raw)
                guard chunk.offset == result.count, !chunk.data.isEmpty,
                    chunk.data.count <= 262_144,
                    result.count + chunk.data.count <= receipt.byteCount,
                    chunk.finished == (result.count + chunk.data.count == receipt.byteCount)
                else { throw ExtensionPeerError.invalidRequest }
                result.append(chunk.data)
            }
            try Task.checkCancellation()
            guard await active(), Self.hash(result) == receipt.sha256.lowercased(),
                UsageHistory.isValidDocument(result)
            else { throw ExtensionPeerError.invalidRequest }
            await release(receipt.collectionID)
            return result
        } catch {
            await release(receipt.collectionID)
            throw error
        }
    }

    private func release(_ id: UUID) async {
        let invoke = invoke
        let cleanup = Task.detached(priority: .utility) {
            _ = try? await invoke(
                "machines.usage.cancel", JSONEncoder().encode(Cancel(collectionID: id)))
        }
        await cleanup.value
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func current() async -> UsageMachinesPeer? {
        await MainActor.run {
            guard let context = SurfaceHostContext.current, context.activeIDs.contains("machines"),
                let endpoint = ExtensionPeerEndpoint.current(owner: "machines"),
                let version = context.activeVersions["machines"]
            else { return nil }
            return UsageMachinesPeer(
                active: {
                    await MainActor.run {
                        context.activeIDs.contains("machines")
                            && context.activeVersions["machines"] == version
                    }
                },
                invoke: { command, data in
                    try await endpoint.invoke(
                        command, payload: data,
                        timeout: command == "machines.usage.collect" ? 900 : 5)
                })
        }
    }

    static func merge(
        local: Data, policy: UsageMachineRefreshPolicy,
        directory: URL = Repo.dataDir, defaults: UserDefaults = SharedDefaults.store,
        onEvent: @escaping @Sendable (UsageRefreshEvent) -> Void
    ) async throws -> Data {
        let selected = Set(
            (defaults.stringArray(forKey: "usageMachines") ?? []).prefix(128).compactMap(
                UUID.init(uuidString:)))
        let registry = await MainActor.run { MachineRegistry.machines() }
        let machines = registry.filter { selected.contains($0.id) && $0.id != Machine.localID }
            .prefix(128)
        let peer = await current()
        var merged = local
        let cacheDirectory = directory.appendingPathComponent("machines")
        for machine in machines {
            try Task.checkCancellation()
            let file = cacheDirectory.appendingPathComponent(
                machine.id.uuidString.lowercased() + ".json")
            var data = try UsageDataFiles.readRegularFile(at: file, maximumBytes: 67_108_864)
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            let due = date.map { Date().timeIntervalSince($0) >= 900 } ?? true
            if let peer, policy == .all || due {
                do {
                    onEvent(.note("Collecting " + String(machine.name.prefix(256))))
                    let collected = try await peer.collect(
                        machineID: machine.id, force: policy == .all)
                    let canonical = try canonicalized(collected, machine: machine)
                    try Task.checkCancellation()
                    try FileManager.default.createDirectory(
                        at: cacheDirectory, withIntermediateDirectories: true)
                    try UsageDataFiles.write(canonical, to: file)
                    data = canonical
                } catch {
                    try Task.checkCancellation()
                    onEvent(
                        .note(
                            String(machine.name.prefix(256)) + ": "
                                + String(error.localizedDescription.prefix(512))))
                }
            }
            if let data, let combined = UsageHistory.merge(local: merged, cloud: data),
                combined.count <= 67_108_864, UsageHistory.isValidDocument(combined)
            {
                merged = combined
            }
        }
        return merged
    }

    static func forget(machineID: UUID, directory: URL = Repo.dataDir) throws {
        try UsageDataTransaction.withExclusiveAccess(dataDirectory: directory) {
            let file = directory.appendingPathComponent("machines").appendingPathComponent(
                machineID.uuidString.lowercased() + ".json")
            if try UsageDataFiles.readRegularFile(at: file, maximumBytes: 67_108_864) != nil {
                try FileManager.default.removeItem(at: file)
            }
            let archives = directory.appendingPathComponent("remote-archives", isDirectory: true)
            let archive = archives.appendingPathComponent(
                machineID.uuidString.lowercased(), isDirectory: true)
            var metadata = stat()
            if lstat(archives.path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(),
                    metadata.st_mode & 0o077 == 0
                else { throw UsageNativeFailure.unsafePath }
                if lstat(archive.path, &metadata) == 0 {
                    guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(),
                        metadata.st_mode & 0o077 == 0
                    else { throw UsageNativeFailure.unsafePath }
                    try FileManager.default.removeItem(at: archive)
                } else if errno != ENOENT {
                    throw UsageNativeFailure.unsafePath
                }
            } else if errno != ENOENT {
                throw UsageNativeFailure.unsafePath
            }
            let usage = directory.appendingPathComponent("usage.json")
            if let data = try UsageDataFiles.readRegularFile(at: usage, maximumBytes: 67_108_864) {
                guard let filtered = UsageHistory.forgetting(machineID: machineID, in: data) else {
                    throw ExtensionPeerError.invalidRequest
                }
                try UsageDataFiles.write(filtered, to: usage)
            }
        }
        UsageEvents.post(UsageEvents.usageUpdated)
    }

    static func canonicalized(_ data: Data, machine: Machine) throws -> Data {
        guard UsageHistory.isValidDocument(data),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sources = object["sources"] as? [String], sources.count <= 100
        else { throw ExtensionPeerError.invalidRequest }
        let mapping = Dictionary(
            uniqueKeysWithValues: sources.filter { !$0.hasPrefix("machine:") }.map {
                ($0, "machine:" + machine.id.uuidString.lowercased() + ":" + $0)
            })
        func transform(_ value: Any, key: String = "") -> Any {
            if let array = value as? [Any] {
                if ["sources", "defaultSources", "sourceIDs"].contains(key) {
                    return array.map { ($0 as? String).flatMap { mapping[$0] } ?? $0 }
                }
                return array.map { transform($0) }
            }
            if let dictionary = value as? [String: Any] {
                return Dictionary(
                    uniqueKeysWithValues: dictionary.map { field, value in
                        (
                            ["bySource", "sourceMeta"].contains(key)
                                ? mapping[field] ?? field : field, transform(value, key: field)
                        )
                    })
            }
            if key == "source", let source = value as? String { return mapping[source] ?? source }
            return value
        }
        var result = transform(object) as! [String: Any]
        result["sources"] = sources.compactMap { mapping[$0] }
        result["defaultSources"] = (object["defaultSources"] as? [String] ?? []).compactMap {
            mapping[$0]
        }
        var meta = result["sourceMeta"] as? [String: [String: Any]] ?? [:]
        for (source, canonical) in mapping {
            var entry = meta[canonical] ?? [:]
            entry["machineID"] = machine.id.uuidString.lowercased();
            entry["machine"] = String(machine.name.prefix(256))
            entry["machineHost"] = String(machine.host.prefix(256));
            entry["label"] = source + " · " + String(machine.name.prefix(256))
            meta[canonical] = entry
        }
        result["sourceMeta"] = meta
        result["machines"] = [
            [
                "id": machine.id.uuidString.lowercased(), "name": String(machine.name.prefix(256)),
                "host": String(machine.host.prefix(256)),
                "collectedAt": object["generatedAt"] ?? "",
                "sources": Array(mapping.values).sorted(),
            ]
        ]
        result.removeValue(forKey: "historyRetention")
        let encoded = try JSONSerialization.data(withJSONObject: result)
        guard encoded.count <= 67_108_864, UsageHistory.isValidDocument(encoded) else {
            throw ExtensionPeerError.invalidRequest
        }
        return encoded
    }
}
