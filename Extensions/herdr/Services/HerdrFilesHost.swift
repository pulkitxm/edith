import EdithExtensionFiles
import EdithExtensionSupport
import Foundation

@MainActor
final class HerdrFilesHost {
    private var sessions: [UUID: DirectFinderSession] = [:]
    private var files: MachineFilesEngine?
    private var previews: MachinePreviewEngine?
    private var exports: MachineDirectoryExport?
    private let machines: @MainActor () -> [Machine]
    private var stopped = false

    init(machines: @escaping @MainActor () -> [Machine] = { MachineRegistry.machines() }) {
        self.machines = machines
    }

    static let operations: Set<String> = [
        "herdr.ui.files", "herdr.ui.files.progress", "herdr.ui.files.preview",
        "herdr.ui.files.export", "herdr.ui.files.session",
    ]

    func session(for id: UUID) throws -> any FinderSession {
        if let existing = sessions[id] { return existing }
        let created: DirectFinderSession
        if id == Machine.localID {
            created = DirectFinderSession(id: id, name: Machine.local.name, isLocal: true)
        } else {
            guard let machine = machines().first(where: { $0.id == id }) else {
                throw MachineUIError.invalidRequest
            }
            let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
            created = DirectFinderSession(
                id: id, name: machine.name, isLocal: false, connection: connection,
                connector: { try await connection.connect() })
        }
        sessions[id] = created
        return created
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopped, Self.operations.contains(command) else {
            throw ExtensionPeerError.unavailable
        }
        let decoder = JSONDecoder()
        let resolve: (UUID) throws -> any FinderSession = { [unowned self] in
            try self.session(for: $0)
        }
        switch command {
        case "herdr.ui.files":
            let engine = filesEngine(resolve)
            return try JSONEncoder().encode(
                try await engine.execute(decoder.decode(MachineFileRequest.self, from: payload)))
        case "herdr.ui.files.progress":
            let engine = filesEngine(resolve)
            return try JSONEncoder().encode(
                try engine.progress(decoder.decode(MachineFileRequest.self, from: payload)))
        case "herdr.ui.files.preview":
            if previews == nil { previews = MachinePreviewEngine(session: resolve) }
            return try await previews!.execute(
                decoder.decode(MachinePreviewRequest.self, from: payload))
        case "herdr.ui.files.session":
            let request = try decoder.decode(FinderSessionRequest.self, from: payload)
            try request.validate()
            return try await perform(request, session: try session(for: request.machineID))
        default:
            if exports == nil { exports = MachineDirectoryExport(session: resolve) }
            return try await exports!.execute(
                decoder.decode(MachineDirectoryExportRequest.self, from: payload))
        }
    }

    private func perform(_ request: FinderSessionRequest, session: any FinderSession) async throws
        -> Data
    {
        let encoder = JSONEncoder()
        switch request.operation {
        case .list: return try encoder.encode(try await session.listFiles(path: request.text).get())
        case .home: return try encoder.encode(try await session.homeDirectory().get())
        case .command:
            return try encoder.encode(
                try await session.runCommand(request.text, timeout: request.timeout).get())
        case .mkdir:
            return try encoder.encode(try await session.createDirectory(path: request.text).get())
        }
    }

    private func filesEngine(_ resolve: @escaping (UUID) throws -> any FinderSession)
        -> MachineFilesEngine
    {
        if let files { return files }
        let engine = MachineFilesEngine(
            session: resolve,
            makeModel: { [unowned self] session, path in
                FinderModel(
                    session: session, path: path,
                    peerSession: { try? self.session(for: $0) })
            })
        files = engine
        return engine
    }

    func shutdown() async {
        stopped = true
        await files?.shutdownAndWait()
        await previews?.drain()
        await exports?.drain()
        previews?.shutdown()
        exports?.shutdown()
        files = nil
        previews = nil
        exports = nil
        sessions = [:]
    }
}
