import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class QuinjetMachines {
    static let shared = QuinjetMachines()
    static let localMachineID = Machine.localID
    let localMachine = Machine.local
    private var saved: [Machine] = []
    private var sessions: [UUID: QuinjetMachineSession] = [:]
    var allMachines: [Machine] { [localMachine] + saved }
    func isLocal(_ id: UUID) -> Bool { id == Self.localMachineID }
    func refresh() async throws {
        try await MachineRegistry.refresh()
        try Task.checkCancellation()
        saved = MachineRegistry.machines()
    }
    func session(for id: UUID) -> QuinjetMachineSession {
        if let session = sessions[id] { return session }
        let session = QuinjetMachineSession(machine: allMachines.first { $0.id == id })
        sessions[id] = session
        return session
    }
    func shutdown() async {
        for session in sessions.values { await session.shutdown() }
        sessions.removeAll()
        saved = []
        MachineRegistry.shutdown()
    }
}

@MainActor @Observable final class QuinjetMachineSession {
    enum State {
        case disconnected, connecting, connected, failed(String)
        var isConnected: Bool { if case .connected = self { return true }; return false }
        var isBusy: Bool { if case .connecting = self { return true }; return false }
        var failureMessage: String? {
            if case let .failed(message) = self { return message }; return nil
        }
    }
    private let machine: Machine?
    private var work: Task<Void, Never>?
    private var stopped = false
    private(set) var state: State = .disconnected
    private(set) var connectionRef: SSHConnection?
    var isLocal: Bool { machine?.id == Machine.localID }
    init(machine: Machine?) { self.machine = machine; if isLocal { state = .connected } }
    func start() {
        guard !stopped, !isLocal, work == nil, let machine else { return }
        state = .connecting
        let connection = SSHConnection(machine: machine)
        work = QuinjetWorkOwnership.start { [weak self] in
            do {
                try await connection.connect()
                try Task.checkCancellation()
                guard let self, !self.stopped else { await connection.disconnect(); return }
                self.connectionRef = connection
                self.state = .connected
            } catch {
                guard let self, !self.stopped else { return }
                self.state = .failed(error.localizedDescription)
            }
            self?.work = nil
        }
    }
    func homeDirectory() async -> Result<String, any Error> {
        do {
            if isLocal {
                return .success(
                    ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
                        ?? FileManager.default.homeDirectoryForCurrentUser.path)
            }
            guard let connectionRef else { throw ExtensionPeerError.unavailable }
            let platform = await connectionRef.remotePlatform ?? .linux
            return .success(
                try await connectionRef.run(FilePlaces.homeDirectoryCommand(platform: platform))
                    .stdoutText)
        } catch { return .failure(error) }
    }
    func listFiles(path: String) async -> Result<[RemoteFileEntry], any Error> {
        do {
            try Task.checkCancellation()
            guard !stopped, QuinjetPath.isAbsolute(path), path.utf8.count <= 4_096,
                !path.utf8.contains(0)
            else { throw ExtensionPeerError.invalidRequest }
            if isLocal {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: path),
                    includingPropertiesForKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                        .contentModificationDateKey,
                    ])
                guard urls.count <= 10_000 else {
                    throw ExtensionPeerError.rejected(
                        "This folder has too many entries. Choose a smaller folder.")
                }
                return .success(
                    try urls.map { url in
                        let values = try url.resourceValues(forKeys: [
                            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                            .contentModificationDateKey,
                        ])
                        return RemoteFileEntry(
                            name: url.lastPathComponent, path: url.path,
                            kind: values.isSymbolicLink == true
                                ? .symlink : values.isDirectory == true ? .directory : .file,
                            sizeBytes: Int64(values.fileSize ?? 0),
                            modified: values.contentModificationDate)
                    })
            }
            guard let connectionRef else { throw ExtensionPeerError.unavailable }
            let platform = await connectionRef.remotePlatform ?? .linux
            let result = try await connectionRef.run(
                FileListing.command(path: path, showHidden: true, platform: platform))
            let entries = FileListing.parse(output: result.stdoutText, parent: path)
            guard entries.count <= 10_000 else { throw ExtensionPeerError.invalidRequest }
            return .success(entries)
        } catch { return .failure(error) }
    }
    func shutdown() async {
        stopped = true
        work?.cancel()
        await work?.value
        work = nil
        await connectionRef?.disconnect()
        connectionRef = nil
        state = .disconnected
    }
}
