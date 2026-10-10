import EdithExtensionSupport
import Foundation
import GhosttyTerminal
import Observation

@MainActor @Observable final class TerminalRemoteClient {
    private let client: ExtensionEngineClient
    private var revision = 0
    private var tasks: [UUID: Task<Data, any Error>] = [:]
    private(set) var snapshot = TerminalEngine.Snapshot(sessions: [], broadcast: false)
    private(set) var error: String?
    private(set) var isStopped = false

    init(client: ExtensionEngineClient) {
        self.client = client
    }

    func refresh() async {
        await update("terminal.snapshot")
    }

    func open() async {
        await update("terminal.open")
    }

    func select(_ session: TerminalEngine.Session) async {
        await update("terminal.select", payload: request(session))
    }

    func close(_ session: TerminalEngine.Session) async {
        await update("terminal.close", payload: request(session))
    }

    func closeAll() async {
        await update("terminal.closeAll")
    }

    func restart(_ session: TerminalEngine.Session) async {
        await update("terminal.restart", payload: request(session))
    }

    func input(_ bytes: Data, to session: TerminalEngine.Session) async throws {
        guard !bytes.isEmpty, bytes.count <= TerminalPTY.maximumInputBytes else {
            throw ExtensionEngineError.rejected
        }
        let payload = try JSONEncoder().encode(
            TerminalEngine.InputRequest(session: checkedRequest(session), bytes: bytes))
        _ = try await invoke("terminal.input", payload: payload)
    }

    func resize(
        _ session: TerminalEngine.Session, columns: UInt16, rows: UInt16, widthPixels: UInt16 = 0,
        heightPixels: UInt16 = 0
    ) async throws {
        guard columns > 0, rows > 0 else { throw ExtensionEngineError.rejected }
        let payload = try JSONEncoder().encode(
            TerminalEngine.ResizeRequest(
                session: checkedRequest(session), columns: columns, rows: rows,
                widthPixels: widthPixels, heightPixels: heightPixels))
        _ = try await invoke("terminal.resize", payload: payload)
    }

    func read(_ session: TerminalEngine.Session, after offset: UInt64) async throws
        -> TerminalPTY.Output
    {
        let owned = try checkedRequest(session)
        let payload = try JSONEncoder().encode(
            TerminalEngine.ReadRequest(session: owned, offset: offset))
        let data = try await invoke("terminal.read", payload: payload)
        _ = try checkedRequest(session)
        let output = try JSONDecoder().decode(TerminalPTY.Output.self, from: data)
        guard output.bytes.count <= 32_768,
            output.nextOffset >= offset,
            output.nextOffset - offset == UInt64(output.bytes.count)
        else { throw ExtensionEngineError.rejected }
        return output
    }

    func presentation(_ session: TerminalEngine.Session, title: String, directory: String)
        async throws
    {
        guard title.utf8.count <= 512, directory.utf8.count <= 4_096,
            !title.utf8.contains(0), !directory.utf8.contains(0)
        else {
            throw ExtensionEngineError.rejected
        }
        let payload = try JSONEncoder().encode(
            TerminalEngine.PresentationRequest(
                session: checkedRequest(session), title: title, directory: directory))
        _ = try await invoke("terminal.presentation", payload: payload)
    }

    func broadcast(_ command: String) async throws -> TerminalBroadcastDelivery {
        guard case let .success(plan) = TerminalBroadcastPlan.make(command: command) else {
            throw ExtensionEngineError.rejected
        }
        let payload = try JSONEncoder().encode(
            TerminalWorker.BroadcastRequest(command: plan.command))
        let data = try await invoke("terminal.broadcast", payload: payload)
        let result = try JSONDecoder().decode(TerminalWorker.BroadcastResult.self, from: data)
        guard result.sent >= 0, result.unavailable >= 0,
            result.sent + result.unavailable <= TerminalTabsModel.maximumTabs
        else { throw ExtensionEngineError.rejected }
        return TerminalBroadcastDelivery(sent: result.sent, unavailable: result.unavailable)
    }

    func importDrop(_ payload: TerminalDropPayload, to session: TerminalEngine.Session) async throws
    {
        let request = try checkedRequest(session)
        if let media = payload.media {
            guard !media.data.isEmpty, UInt64(media.data.count) <= TerminalEngineFiles.maximumBytes
            else { throw ExtensionEngineError.rejected }
            let data = try await invoke(
                "terminal.drop.begin",
                payload: JSONEncoder().encode(
                    TerminalEngineFiles.Begin(session: request, fileExtension: media.fileExtension))
            )
            let handle = try JSONDecoder().decode(TerminalEngineFiles.Handle.self, from: data)
            guard handle.session.id == request.id, handle.session.generation == request.generation
            else { throw ExtensionEngineError.rejected }
            do {
                var offset = 0
                while offset < media.data.count {
                    _ = try checkedRequest(session)
                    let bytes = Data(media.data.dropFirst(offset).prefix(16_384))
                    let reply = try await invoke(
                        "terminal.drop.write",
                        payload: JSONEncoder().encode(
                            TerminalEngineFiles.Chunk(
                                handle: handle, offset: UInt64(offset), bytes: bytes)))
                    let receipt = try JSONDecoder().decode(
                        TerminalEngineFiles.Receipt.self, from: reply)
                    guard receipt.offset == UInt64(offset + bytes.count) else {
                        throw ExtensionEngineError.rejected
                    }
                    offset += bytes.count
                }
                _ = try await invoke("terminal.drop.finish", payload: JSONEncoder().encode(handle))
            } catch {
                _ = try? await invoke("terminal.drop.cancel", payload: JSONEncoder().encode(handle))
                throw error
            }
        } else {
            guard !payload.files.isEmpty, payload.files.count <= 32 else {
                throw ExtensionEngineError.rejected
            }
            let items = payload.files.map {
                TerminalEngineFiles.Paths.Item(
                    path: $0.path, temporary: payload.temporaryFiles.contains($0))
            }
            _ = try await invoke(
                "terminal.drop.paths",
                payload: JSONEncoder().encode(
                    TerminalEngineFiles.Paths(session: request, items: items)))
        }
    }

    func resolveLink(_ value: String, untrusted: Bool, session: TerminalEngine.Session) async throws
        -> TerminalEngineFiles.LinkReply
    {
        let request = TerminalEngineFiles.Link(
            session: try checkedRequest(session), value: value, untrusted: untrusted)
        let data = try await invoke("terminal.resolveLink", payload: JSONEncoder().encode(request))
        _ = try checkedRequest(session)
        let reply = try JSONDecoder().decode(TerminalEngineFiles.LinkReply.self, from: data)
        guard reply.resolution.target.utf8.count <= 32_768,
            reply.resolution.detail.utf8.count <= 1_024,
            (reply.resolution.disposition == .deny) == (reply.token == nil)
        else { throw ExtensionEngineError.rejected }
        return reply
    }

    func openLink(_ token: UUID, session: TerminalEngine.Session) async throws {
        let handle = TerminalEngineFiles.Handle(session: try checkedRequest(session), token: token)
        _ = try await invoke("terminal.openLink", payload: JSONEncoder().encode(handle))
    }

    func preferences() async throws -> TerminalSettings {
        let data = try await invoke("terminal.preferences", payload: Data("{}".utf8))
        let settings = try JSONDecoder().decode(TerminalSettings.self, from: data)
        try settings.validate()
        return settings
    }

    func savePreferences(_ settings: TerminalSettings) async throws -> TerminalSettings {
        try settings.validate()
        let data = try await invoke(
            "terminal.savePreferences", payload: JSONEncoder().encode(settings))
        let saved = try JSONDecoder().decode(TerminalSettings.self, from: data)
        try saved.validate()
        revision += 1
        snapshot = TerminalEngine.Snapshot(
            sessions: snapshot.sessions, broadcast: snapshot.broadcast, preferences: saved)
        return saved
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        revision += 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        client.invalidate()
        snapshot = TerminalEngine.Snapshot(sessions: [], broadcast: false)
    }

    private func update(_ operation: String, payload: Data = Data("{}".utf8)) async {
        guard !isStopped else { return }
        revision += 1
        let current = revision
        do {
            let data = try await invoke(operation, payload: payload)
            let next = try JSONDecoder().decode(TerminalEngine.Snapshot.self, from: data)
            try Self.validate(next)
            guard !isStopped, revision == current else { return }
            snapshot = next
            error = nil
        } catch is CancellationError {
        } catch {
            guard !isStopped, revision == current else { return }
            self.error = "The owned terminal engine is unavailable."
        }
    }

    private func invoke(_ operation: String, payload: Data) async throws -> Data {
        while !isStopped, tasks.count >= (operation == "terminal.read" ? 4 : 8) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        guard !isStopped else { throw ExtensionEngineError.unavailable }
        try Task.checkCancellation()
        let token = UUID()
        let task = Task { try await client.invoke(operation, payload: payload) }
        tasks[token] = task
        defer { tasks[token] = nil }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard !isStopped else { throw ExtensionEngineError.unavailable }
        return result
    }

    private func request(_ session: TerminalEngine.Session) -> Data {
        (try? JSONEncoder().encode(
            TerminalEngine.SessionRequest(id: session.id, generation: session.generation)))
            ?? Data()
    }

    private func checkedRequest(_ session: TerminalEngine.Session) throws
        -> TerminalEngine.SessionRequest
    {
        guard !isStopped,
            snapshot.sessions.contains(where: {
                $0.id == session.id && $0.generation == session.generation
            })
        else { throw ExtensionEngineError.rejected }
        return TerminalEngine.SessionRequest(id: session.id, generation: session.generation)
    }

    private static func validate(_ snapshot: TerminalEngine.Snapshot) throws {
        try snapshot.preferences.validate()
        guard snapshot.sessions.count <= TerminalTabsModel.maximumTabs,
            Set(snapshot.sessions.map(\.id)).count == snapshot.sessions.count,
            snapshot.sessions.filter(\.selected).count <= 1,
            snapshot.sessions.allSatisfy({
                $0.title.utf8.count <= 512 && $0.directory.utf8.count <= 4_096
                    && !$0.title.utf8.contains(0) && !$0.directory.utf8.contains(0)
                    && ($0.error?.utf8.count ?? 0) <= 512
                    && $0.running == ($0.exitCode == nil && $0.error == nil)
            })
        else { throw ExtensionEngineError.rejected }
    }
}
