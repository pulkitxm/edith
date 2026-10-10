import Foundation

@MainActor final class MachinePreviewEngine {
    private struct Preview {
        let machineID: UUID
        let file: FileHandle
        let count: UInt64
        var offset: UInt64
        var touched: Date
    }
    private var previews: [UUID: Preview] = [:]
    private let session: (UUID) throws -> MachineSession
    private var stopped = false
    private var reaper: Task<Void, Never>?

    init(session: @escaping (UUID) throws -> MachineSession) { self.session = session }

    func execute(_ value: MachinePreviewRequest) async throws -> Data {
        guard !stopped, value.maximumBytes > 0,
            value.maximumBytes <= RemoteFileOperationExecution.cacheLimitBytes
        else { throw MachineUIError.invalidRequest }
        switch value.operation {
        case .prepare:
            guard previews.count < 8, let entry = value.entry,
                !entry.isDirectory, entry.path.utf8.count <= 4_096, !entry.path.utf8.contains(0)
            else { throw MachineUIError.invalidRequest }
            let session = try session(value.machineID)
            let url = try await RemoteFileOperationExecution.materialize(
                entry, machineID: session.id, isLocal: session.isLocal,
                maximumBytes: value.maximumBytes
            ) { path, destination in
                guard let connection = session.connectionRef else {
                    throw FinderTransferError.notConnected
                }
                try await connection.download(remotePath: path, to: destination)
            }
            try Task.checkCancellation()
            guard !stopped else { throw MachineUIError.unavailable }
            let file = try FileHandle(forReadingFrom: url)
            let count = try file.seekToEnd()
            guard count <= UInt64(value.maximumBytes) else {
                try file.close(); throw MachineUIError.invalidRequest
            }
            try file.seek(toOffset: 0)
            let id = UUID()
            previews[id] = Preview(
                machineID: session.id, file: file, count: count, offset: 0, touched: Date())
            startReaper()
            return try JSONEncoder().encode(
                MachinePreviewHandle(id: id, count: count, name: entry.name))
        case .read:
            guard let id = value.id, var preview = previews[id],
                preview.machineID == value.machineID, value.offset == preview.offset
            else { throw MachineUIError.invalidRequest }
            let bytes = try preview.file.read(upToCount: 65_536) ?? Data()
            preview.touched = Date()
            preview.offset += UInt64(bytes.count)
            guard preview.offset <= preview.count else { throw MachineUIError.invalidRequest }
            previews[id] = preview
            let complete = preview.offset == preview.count
            if complete { try preview.file.close(); previews.removeValue(forKey: id) }
            return try JSONEncoder().encode(
                MachinePreviewChunk(offset: value.offset, bytes: bytes, complete: complete))
        case .close:
            guard let id = value.id else { throw MachineUIError.invalidRequest }
            if let preview = previews[id] {
                guard preview.machineID == value.machineID else {
                    throw MachineUIError.invalidRequest
                }
                try preview.file.close(); previews.removeValue(forKey: id)
            }
            return try JSONEncoder().encode(true)
        }
    }

    private func startReaper() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !stopped else { return }
                for id in previews.keys.filter({
                    Date().timeIntervalSince(self.previews[$0]!.touched) > 10
                }) {
                    if let value = previews.removeValue(forKey: id) { try? value.file.close() }
                }
            }
        }
    }

    func shutdown() {
        stopped = true
        reaper?.cancel(); reaper = nil
        for preview in previews.values { try? preview.file.close() }
        previews = [:]
    }
}
