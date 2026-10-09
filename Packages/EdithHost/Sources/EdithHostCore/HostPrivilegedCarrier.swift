import Darwin
import EdithExtensionSupport
import ExtensionMarketplace
import Foundation
import Security

@MainActor public final class HostPrivilegedCarrier: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener(machServiceName: ExtensionPrivilegedService.identifier)
    private let team: String
    private var sessions: [UUID: HostPrivilegedSession] = [:]
    private let leases = HostPrivilegedLeases()

    public init(approved: Bool) throws {
        guard approved, getuid() == 0, let team = ExtensionCodeSignature.teamIdentifier() else {
            throw MarketplaceError.invalidSignature
        }
        self.team = team
        super.init(); listener.delegate = self
    }

    public func run() { listener.resume(); RunLoop.current.run() }

    public nonisolated func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier,
            let requirement = try? HostPrivilegedCaller.requirement(
                hostIdentifier: identifier, team: team)
        else { return false }
        Self.bindAcceptedConnection(
            connection,
            requirement: requirement
        ) { [self] box in
            let connection = box.connection
            guard sessions.count < 8 else { connection.invalidate(); return }
            let id = UUID()
            let admission = HostPrivilegedAdmission(
                root: URL(fileURLWithPath: "/Library/Application Support/Edith Extension Carrier")
            ) { [team] in try ExtensionCodeSignature.verify($0, teamIdentifier: team) }
            let session = HostPrivilegedSession(
                admission: admission,
                authorize: { [team] source, owner, version in
                    let caller = try HostPrivilegedCaller.read(
                        processIdentifier: connection.processIdentifier,
                        hostIdentifier: identifier, team: team)
                    try caller.authorize(source: source, owner: owner, version: version)
                },
                reserveOwner: { [leases] in leases.reserve($0) },
                releaseOwner: { [leases] in leases.release($0) }
            ) { [weak self] in
                connection.invalidate(); connection.exportedObject = nil
                self?.sessions[id] = nil
                guard self?.sessions.isEmpty == true else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    if self?.sessions.isEmpty == true { exit(0) }
                }
            }
            sessions[id] = session
            connection.exportedInterface = NSXPCInterface(with: ExtensionPrivilegedProtocol.self)
            connection.exportedObject = session
            connection.invalidationHandler = { Task { @MainActor in session.connectionLost() } }
            connection.interruptionHandler = connection.invalidationHandler
            connection.resume()
        }
        return true
    }

    nonisolated static func bindAcceptedConnection(
        _ connection: NSXPCConnection,
        requirement: String, bind: @escaping @MainActor (HostPrivilegedConnection) -> Void
    ) {
        connection.setCodeSigningRequirement(requirement)
        let box = HostPrivilegedConnection(connection)
        Task { @MainActor in bind(box) }
    }

}

@MainActor final class HostPrivilegedSession: NSObject, ExtensionPrivilegedProtocol {
    private let admission: HostPrivilegedAdmission
    private let ended: @MainActor () -> Void
    private var worker: HostPrivilegedProcess?
    private var payload: URL?
    private var restoration: Task<Void, Never>?
    private var releasing = false
    private var finished = false
    private var owner: String?
    private let authorize: @MainActor (URL, String, String) throws -> Void
    private let reserveOwner: @MainActor (String) -> Bool
    private let releaseOwner: @MainActor (String) -> Void
    private let makeWorker: @MainActor (URL) throws -> HostPrivilegedProcess

    init(
        admission: HostPrivilegedAdmission,
        authorize: @escaping @MainActor (URL, String, String) throws -> Void = { _, _, _ in },
        reserveOwner: @escaping @MainActor (String) -> Bool,
        releaseOwner: @escaping @MainActor (String) -> Void,
        makeWorker: @escaping @MainActor (URL) throws -> HostPrivilegedProcess = { payload in
            guard let executable = Bundle.main.executableURL else {
                throw MarketplaceError.invalidBundle
            }
            return HostPrivilegedProcess(
                executable: executable,
                arguments: ["--extension-carrier-worker", payload.path])
        }, ended: @escaping @MainActor () -> Void
    ) {
        self.admission = admission; self.ended = ended; self.authorize = authorize
        self.reserveOwner = reserveOwner; self.releaseOwner = releaseOwner;
        self.makeWorker = makeWorker
    }

    nonisolated func activate(
        _ source: String, owner: String, version: String,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        Task { @MainActor in
            guard self.worker == nil, !self.releasing, !self.finished else {
                reply(MarketplaceError.invalidBundle as NSError); return
            }
            do {
                try self.authorize(URL(fileURLWithPath: source), owner, version)
            } catch { reply(error as NSError); return }
            guard self.reserveOwner(owner) else {
                reply(
                    ExtensionPeerError.rejected(
                        "This extension already owns a privileged worker. Wait for restoration, then try again."
                    ) as NSError);
                return
            }
            self.owner = owner
            do {
                let payload = try self.admission.admit(
                    source: URL(fileURLWithPath: source), owner: owner, version: version)
                self.payload = payload
                try await self.startWorker(payload)
                reply(nil)
            } catch { reply(error as NSError); self.finish() }
        }
    }

    nonisolated func invoke(
        _ command: String, payload: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        Task { @MainActor in
            guard !self.releasing, let worker = self.worker, !command.isEmpty,
                command.utf8.count <= 256, !command.utf8.contains(0), payload.count <= 32_768
            else { reply(nil, MarketplaceError.invalidBundle as NSError); return }
            do { reply(try await worker.invoke(command, payload: payload), nil) } catch {
                reply(nil, error as NSError)
            }
        }
    }

    nonisolated func release(reply: @escaping @Sendable (NSError?) -> Void) {
        Task { @MainActor in
            guard !self.releasing else {
                reply(
                    ExtensionPeerError.rejected("System settings are still being restored.")
                        as NSError);
                return
            }
            self.releasing = true
            do { try await self.prepare(); reply(nil); self.finish() } catch {
                self.releasing = false; reply(error as NSError)
            }
        }
    }

    func connectionLost() {
        guard restoration == nil, !finished else { return }
        releasing = true
        restoration = Task { [self] in
            while !Task.isCancelled {
                do { try await prepare(); finish(); return } catch {
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    private func startWorker(_ payload: URL) async throws {
        let created = try makeWorker(payload); worker = created
        created.didExit = { [weak self] in
            guard self?.releasing == false else { return }; self?.connectionLost()
        }
        try await created.start()
    }

    private func prepare() async throws {
        if worker?.processIdentifier == nil, let payload { try await startWorker(payload) }
        try await worker?.stop()
    }

    private func finish() {
        guard !finished else { return }; finished = true
        worker = nil
        if let owner { releaseOwner(owner); self.owner = nil }
        if let payload { try? admission.remove(payload); self.payload = nil }
        ended()
    }
}

final class HostPrivilegedConnection: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}

@MainActor final class HostPrivilegedLeases {
    private var owners = Set<String>()
    func reserve(_ owner: String) -> Bool { owners.insert(owner).inserted }
    func release(_ owner: String) { owners.remove(owner) }
}
