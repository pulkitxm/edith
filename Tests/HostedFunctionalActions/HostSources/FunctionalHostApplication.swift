import AppKit
import CryptoKit
import Darwin
import EdithExtensionSupport
import EdithHostCore
import ExtensionMarketplace
import Foundation
import WorkerFixtureSupport

@MainActor
enum FunctionalHostApplication {
    private static var installed = false
    private static var socket: FunctionalHostSocket?
    private static var sessions: [String: FunctionalHostSession] = [:]
    private static var requestIDs = Set<String>()
    private static var pending = false
    private static var joinedUICommands: [String: Set<String>] = [:]

    static func installHooks() throws {
        if installed { return }
        let root = try FunctionalPinnedPath(URL(fileURLWithPath: FunctionalHostBuild.root), directory: true, privateMode: true)
        try root.requireCurrent()
        guard FunctionalBytes.uuid(FunctionalHostBuild.session),
            FunctionalHostBuild.hostIdentifier == "com.pulkit.edith.tests.worker-" + FunctionalHostBuild.session,
            let identifier = Bundle.main.bundleIdentifier,
            identifier == FunctionalHostBuild.hostIdentifier || identifier.hasPrefix(FunctionalHostBuild.hostIdentifier + ".extension."),
            FunctionalHostBuild.issuerPublicKey.count == 32
        else { throw FunctionalFailure.invalid("compiled Host entry identity") }
        let birth = try FunctionalBirth.observe(getpid())
        try FunctionalSigner(identifier: identifier, certificateSHA256: FunctionalHostBuild.certificateSHA256,
            requirement: "identifier \"" + identifier + "\"").verify(Bundle.main.bundleURL, birth: birth)
        HostWorker.fixtureBeforeConfiguration = { worker, birth in
            guard let session = sessions[worker.configuration.extensionID] else {
                throw FunctionalFailure.invalid("owned original starting session") }
            try await session.prepareStartingWorker(worker, birth: birth)
        }
        HostRemoteSessionManager.fixtureAdmitStartingReservation = { configuration, engine, request in
            guard configuration.uiOnly == false, configuration.worker.extensionID == request.extensionID else {
                throw FunctionalFailure.invalid("original starting engine reservation") }
            _ = try FunctionalHostBootstrap.rendezvous(operation: "admit-starting-reservation",
                owner: configuration.worker.extensionID, fields: ["configuration": try encoded(configuration),
                    "engine": try kernel(engine), "request": try encoded(request)])
        }
        HostWorkerApplication.fixtureAdmitBeforeConstruction = { configuration, context, roles in
            let response = try FunctionalHostBootstrap.rendezvous(operation: "admit-engine",
                owner: configuration.extensionID, fields: ["configuration": try encoded(configuration)])
            let marked = try markedContext(context, response: response)
            return try admitRoles(owner: configuration.extensionID, roles: roles, context: marked, purpose: .engine)
        }
        HostRemoteApplication.fixtureAdmitConfiguration = { configuration in
            _ = try FunctionalHostBootstrap.rendezvous(operation: "admit-ui", owner: configuration.worker.extensionID,
                fields: ["configuration": try encoded(configuration)])
        }
        HostRemoteApplication.fixtureAdmitBeforeConstruction = { configuration, presentation, context, roles in
            let response = try FunctionalHostBootstrap.rendezvous(operation: "admit-ui",
                owner: configuration.worker.extensionID, fields: ["configuration": try encoded(configuration),
                    "presentation": try encoded(presentation)])
            let marked = try markedContext(context, response: response)
            return try admitRoles(owner: configuration.worker.extensionID, roles: roles, context: marked, purpose: .ui)
        }
        ExtensionPeerServer.fixtureBeforeExecute = { invocation in
            let owner = try engineOwner(invocation)
            _ = try FunctionalHostBootstrap.rendezvous(operation: "before-engine-receiver", owner: owner,
                fields: try engineInvocationFields(invocation, owner: owner))
        }
        ExtensionPeerServer.fixtureAfterExecute = { invocation, payload, failure in
            let owner = try engineOwner(invocation)
            var fields = try engineInvocationFields(invocation, owner: owner)
            guard (payload == nil) != (failure == nil) else {
                throw FunctionalFailure.invalid("actual engine execution outcome") }
            if let payload {
                var result: [String: Any] = ["ok": true, "payloadSHA256": FunctionalBytes.digest(payload),
                    "payloadBytes": payload.count]
                result["payload"] = payload.base64EncodedString()
                fields["result"] = result
            } else { fields["result"] = ["ok": false] }
            _ = try FunctionalHostBootstrap.rendezvous(operation: "after-engine-receiver", owner: owner, fields: fields)
        }
        HostRemoteSession.fixtureBeforeEngineRequest = { invocation in
            let fields = try invocationFields(invocation)
            _ = try FunctionalHostBootstrap.rendezvous(operation: "before-original-request",
                owner: try originalOwner(invocation.ui.executable), fields: fields)
        }
        HostRemoteSession.fixtureObserveEngineResult = { invocation, result in
            var fields = try invocationFields(invocation)
            switch result {
            case .success(let bytes):
                var result: [String: Any] = ["ok": true, "payloadSHA256": FunctionalBytes.digest(bytes), "payloadBytes": bytes.count]
                result["payload"] = bytes.base64EncodedString()
                fields["result"] = result
            case .failure:
                fields["result"] = ["ok": false]
            }
            _ = try FunctionalHostBootstrap.rendezvous(operation: "after-original-response", owner: try originalOwner(invocation.ui.executable), fields: fields)
        }
        HostRemoteSession.fixtureObserveNativeReply = { observation in
            guard observation.reply.token == observation.invocation.request.token,
                observation.encodedReply.count <= 1_048_576
            else { throw FunctionalFailure.invalid("actual native response correlation") }
            let owner = try originalOwner(observation.invocation.ui.executable)
            _ = try FunctionalHostBootstrap.rendezvous(operation: "native-emitted-reply", owner: owner, fields: [
                "ui": try peer(observation.invocation.ui), "receiver": try kernel(observation.invocation.receiver),
                "request": try request(observation.invocation.request, owner: owner),
                "reply": observedReply(observation.reply, owner: owner),
                "encodedReplySHA256": FunctionalBytes.digest(observation.encodedReply),
            ])
        }
        HostWorkerApplication.fixtureObserveCommandCancellation = { token in
            let owner = ProcessInfo.processInfo.environment["EDITH_EXTENSION_ID"] ?? ""
            _ = try FunctionalHostBootstrap.rendezvous(operation: "command-cancelled", owner: owner,
                fields: ["token": token.uuidString.lowercased(), "side": "engine"])
        }
        HostWorkerApplication.fixtureObserveCommandRetirementStarted = { tokens in
            let owner = ProcessInfo.processInfo.environment["EDITH_EXTENSION_ID"] ?? ""
            _ = try FunctionalHostBootstrap.rendezvous(operation: "command-retirement-started", owner: owner,
                fields: ["tokens": tokens.map { $0.uuidString.lowercased() }, "side": "engine"])
        }
        HostRemoteApplication.fixtureObserveCommandCancellation = { token in
            guard let owner = Bundle.main.object(forInfoDictionaryKey: "EdithExtensionID") as? String else {
                throw FunctionalFailure.invalid("native cancellation owner") }
            _ = try FunctionalHostBootstrap.rendezvous(operation: "command-cancelled", owner: owner,
                fields: ["token": token.uuidString.lowercased(), "side": "ui"])
        }
        HostRemoteApplication.fixtureObserveCommandRetirementStarted = { tokens in
            guard let owner = Bundle.main.object(forInfoDictionaryKey: "EdithExtensionID") as? String else {
                throw FunctionalFailure.invalid("native retirement snapshot owner") }
            _ = try FunctionalHostBootstrap.rendezvous(operation: "command-retirement-started", owner: owner,
                fields: ["tokens": tokens.map { $0.uuidString.lowercased() }, "side": "ui"])
        }
        HostWorkerApplication.fixtureObserveCommandRetirement = { token in
            let owner = ProcessInfo.processInfo.environment["EDITH_EXTENSION_ID"] ?? ""
            _ = try FunctionalHostBootstrap.rendezvous(operation: "owner-joined", owner: owner,
                fields: ["token": token.uuidString.lowercased(), "side": "engine"])
        }
        HostRemoteApplication.fixtureObserveCommandRetirement = { token in
            guard let owner = Bundle.main.object(forInfoDictionaryKey: "EdithExtensionID") as? String else {
                throw FunctionalFailure.invalid("native retirement owner") }
            _ = try FunctionalHostBootstrap.rendezvous(operation: "owner-joined", owner: owner,
                fields: ["token": token.uuidString.lowercased(), "side": "ui"])
            guard joinedUICommands[owner, default: []].insert(token.uuidString.lowercased()).inserted else {
                throw FunctionalFailure.invalid("duplicate source UI command retirement") }
        }
        HostRemoteApplication.fixtureObserveStopPreparation = { observation in
            guard let configuration = observation.configuration else { throw FunctionalFailure.invalid("unconfigured UI preparation") }
            _ = try FunctionalHostBootstrap.rendezvous(operation: "native-stop-prepared", owner: configuration.worker.extensionID, fields: [
                "token": observation.token.uuidString.lowercased(), "configuration": try encoded(configuration),
                "roles": observation.roles, "presentations": observation.presentations.map { $0.uuidString.lowercased() },
                "joinedCommands": joinedUICommands[configuration.worker.extensionID, default: []].sorted(),
            ])
        }
        HostWorker.fixtureObserveStop = { observation in
            _ = try FunctionalHostBootstrap.rendezvous(operation: "engine-stop-observed", owner: observation.configuration.extensionID,
                fields: ["receipt": try encoded(observation)])
        }
        HostRemoteSession.fixtureObserveStop = { observation in
            _ = try FunctionalHostBootstrap.rendezvous(operation: "native-stop-observed", owner: observation.configuration.worker.extensionID, fields: [
                "configuration": try encoded(observation.configuration), "joinedTasks": observation.joinedTasks,
                "stopRequest": try observation.stopRequest.map(encoded) ?? NSNull(),
                "stopReply": try observation.stopReply.map(encoded) ?? NSNull(),
                "ui": observation.ui.map(capturedPeer) ?? NSNull(),
                "engine": observation.engine.map(capturedKernel) ?? NSNull(),
                "observedBirths": try observation.observedBirths.map(encoded),
                "signalAttempts": try observation.signalAttempts.map(encoded),
                "invalidations": observation.invalidations.map { attempt in
                    var fields: [String: Any] = ["site": attempt.site]
                    if let identity = attempt.peer { fields["peer"] = capturedPeer(identity) }
                    else { fields["peer"] = NSNull() }
                    if let running = attempt.peerWasRunning { fields["peerWasRunning"] = running }
                    else { fields["peerWasRunning"] = NSNull() }
                    return fields
                },
            ])
        }
        installed = true
    }

    static func run() throws {
        try installHooks()
        let environment = ProcessInfo.processInfo.environment
        guard let eventPath = environment["GITHUB_EVENT_PATH"],
            let event = try JSONSerialization.jsonObject(with:
                FunctionalPinnedPath(URL(fileURLWithPath: eventPath), directory: false, maximum: 4_194_304).read()) as? [String: Any]
        else { throw FunctionalFailure.invalid("actual Host event context") }
        try FunctionalHostedRunAdmission.requireEnvironment(environment, pins: FunctionalHostBuild.hostedRunPins, event: event)
        guard Bundle.main.bundleIdentifier == FunctionalHostBuild.hostIdentifier,
            Bundle.main.executableURL?.path == FunctionalHostBuild.root + "/Fixture.app/Contents/MacOS/Edith", socket == nil
        else { throw FunctionalFailure.invalid("disposable hosted Host execution only") }
        let root = try FunctionalPinnedPath(URL(fileURLWithPath: FunctionalHostBuild.root), directory: true, privateMode: true)
        socket = try FunctionalHostSocket(root: root, endpoint: .host) { caller, message in
            try await receive(caller, message, root: root)
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.run()
    }

    private static func receive(_ caller: FunctionalSocketPeer, _ message: [String: Any], root: FunctionalPinnedPath) async throws -> Data {
        guard caller.birth.executable == FunctionalHostBuild.producerExecutable,
            caller.birth.executableSHA256 == FunctionalHostBuild.producerExecutableSHA256,
            message["schema"] as? Int == 1, message["sourceCommit"] as? String == FunctionalHostBuild.sourceCommit,
            message["session"] as? String == FunctionalHostBuild.session,
            let requestID = message["requestID"] as? String, FunctionalBytes.uuid(requestID),
            requestIDs.count < 4096, requestIDs.insert(requestID).inserted, !pending,
            let operation = message["operation"] as? String, let owner = message["owner"] as? String,
            HostedFunctionalActionContext.owners.contains(owner)
        else { throw FunctionalFailure.invalid("source-owned Host controller") }
        try FunctionalSigner(identifier: FunctionalHostBuild.producerIdentifier,
            certificateSHA256: FunctionalHostBuild.certificateSHA256,
            requirement: "identifier \"" + FunctionalHostBuild.producerIdentifier + "\"")
            .verify(URL(fileURLWithPath: caller.birth.executable), birth: caller.birth)
        pending = true
        defer { pending = false }
        var response: [String: Any] = ["schema": 1, "sourceCommit": FunctionalHostBuild.sourceCommit,
            "session": FunctionalHostBuild.session, "requestID": requestID, "operation": operation, "owner": owner]
        let common = ["schema", "sourceCommit", "session", "requestID", "operation", "owner"]
        switch operation {
        case "shutdown":
            try FunctionalBytes.exact(message, Set(common))
            guard sessions.isEmpty else { throw FunctionalFailure.invalid("Host shutdown before original session joins") }
            response["naturalTerminationScheduled"] = true
            Task { @MainActor in
                do {
                    guard let socket else { throw FunctionalFailure.invalid("missing Host listener on retirement") }
                    try await socket.closeAndJoin()
                    self.socket = nil
                    NSApplication.shared.terminate(nil)
                } catch { exit(1) }
            }
        case "create-session":
            try FunctionalBytes.exact(message, Set(common + ["catalogs"]))
            guard sessions[owner] == nil, sessions.count < 3, let catalogs = message["catalogs"] as? [String], catalogs.count == 2 else {
                throw FunctionalFailure.invalid("bounded original owner session") }
            var packages: [ExtensionPackage] = [], archives: [String: FunctionalPinnedPath] = [:]
            var first: Data?
            for (index, text) in catalogs.enumerated() {
                guard let bytes = Data(base64Encoded: text), bytes.count <= 1_048_576, bytes.base64EncodedString() == text else {
                    throw FunctionalFailure.invalid("source issuer catalog bytes") }
                let catalog = try JSONDecoder().decode(SignedExtensionCatalog.self, from: bytes)
                    .verified(publicKey: FunctionalHostBuild.issuerPublicKey, repository: "pulkitxm/edith")
                guard catalog.packages.count == 1, let package = catalog.packages.first,
                    package.id == owner, package.version == (index == 0 ? "1.0.0" : "1.1.0") else {
                    throw FunctionalFailure.invalid("source original owner pair") }
                packages.append(package)
                archives[package.version] = try FunctionalPinnedPath(root.url.appendingPathComponent("packages-" + owner + "-" + package.version + "/" + owner + ".zip"), directory: false, maximum: 1_073_741_824)
                if index == 0 { first = bytes }
            }
            guard let first else { throw FunctionalFailure.invalid("initial catalog") }
            sessions[owner] = try FunctionalHostSession(owner: owner, packages: packages, catalog: first, archives: archives, root: root)
        case "select-catalog":
            try FunctionalBytes.exact(message, Set(common + ["catalog"]))
            guard let session = sessions[owner], let text = message["catalog"] as? String,
                let bytes = Data(base64Encoded: text), bytes.count <= 1_048_576 else { throw FunctionalFailure.invalid("selected catalog bytes") }
            try await session.selectCatalog(bytes)
        case "install":
            try FunctionalBytes.exact(message, Set(common + ["version"]))
            guard let session = sessions[owner], let version = message["version"] as? String else { throw FunctionalFailure.invalid("installer session") }
            try await session.install(version: version)
        case "open-original":
            try FunctionalBytes.exact(message, Set(common + ["phase", "location", "section", "presentationID"]))
            guard let session = sessions[owner], let phase = message["phase"] as? String,
                let location = message["location"] as? String, let section = message["section"] as? String,
                let text = message["presentationID"] as? String, FunctionalBytes.uuid(text), let presentationID = UUID(uuidString: text)
            else { throw FunctionalFailure.invalid("original presentation binding") }
            let handle = try await session.openOriginal(phase: phase, location: location, section: section, presentationID: presentationID)
            guard let identity = handle.processIdentity else { throw FunctionalFailure.invalid("original UI identity") }
            response["ui"] = try peer(identity)
        case "read-original-state":
            try FunctionalBytes.exact(message, Set(common + ["token", "readOperation", "payload"]))
            guard let session = sessions[owner], let text = message["token"] as? String,
                FunctionalBytes.uuid(text), let token = UUID(uuidString: text),
                let operation = message["readOperation"] as? String, let encoded = message["payload"] as? String,
                let payload = Data(base64Encoded: encoded), payload.base64EncodedString() == encoded,
                payload.count <= 262_144 else { throw FunctionalFailure.invalid("source readonly request fields") }
            let result = try await session.readOriginalState(token: token, operation: operation, payload: payload)
            response["token"] = text
            response["payload"] = result.base64EncodedString()
            response["payloadSHA256"] = FunctionalBytes.digest(result)
        case "drain":
            try FunctionalBytes.exact(message, Set(common))
            guard let session = sessions[owner] else { throw FunctionalFailure.invalid("original drain session") }
            response["drain"] = try await session.closeAndDrain()
        case "remove":
            try FunctionalBytes.exact(message, Set(common))
            guard let session = sessions[owner] else { throw FunctionalFailure.invalid("original removal session") }
            response["removedVersions"] = try await session.remove()
        case "retire-session":
            try FunctionalBytes.exact(message, Set(common))
            guard let session = sessions[owner] else { throw FunctionalFailure.invalid("original session retirement") }
            try await session.stop()
            sessions.removeValue(forKey: owner)
        default: throw FunctionalFailure.invalid("unadmitted Host lifecycle command")
        }
        try root.requireCurrent()
        try caller.birth.requireCurrent()
        return try FunctionalBytes.canonical(response)
    }

    private static func admitRoles(owner: String, roles: [URL], context: NSDictionary, purpose: WorkerFixtureBootstrapPurpose) throws -> [HostFixtureRoleAdmission] {
        guard !roles.isEmpty, roles.count <= 3,
            let trust = WorkerFixtureBootstrapTrustAnchor.admitted
        else { throw FunctionalFailure.invalid("original role count or compiled trust") }
        let policy = try trust.rolePolicy(owner: owner)
        let selected = roles.filter { $0.deletingPathExtension().lastPathComponent == policy.primaryRole.rawValue }
        guard selected.count == 1 else { throw FunctionalFailure.invalid("compiled original primary role missing or duplicated") }
        return try selected.map { url in
            guard url.pathExtension == "bundle", let role = WorkerFixtureRole(rawValue: url.deletingPathExtension().lastPathComponent),
                let authority = try WorkerFixtureBootstrapAdmission.current(extensionID: owner, context: context,
                    roleURL: url, expectedRole: role, purpose: purpose)
            else { throw FunctionalFailure.invalid("independently admitted original role") }
            return HostFixtureRoleAdmission(roleDirectory: url, contextMarker: authority.contextMarker,
                revalidate: { try authority.requireCurrent() })
        }
    }

    private static func markedContext(_ original: NSDictionary, response: [String: Any]) throws -> NSDictionary {
        guard let marker = response["contextMarker"] as? [String: String] else { throw FunctionalFailure.invalid("signed source context marker") }
        guard let context = original.mutableCopy() as? NSMutableDictionary else { throw FunctionalFailure.invalid("source role context") }
        context["hostedFunctionalFixture"] = marker
        return context
    }

    private static func invocationFields(_ invocation: HostRemoteSession.FixtureEngineInvocation) throws -> [String: Any] {
        let owner = try originalOwner(invocation.ui.executable)
        return ["ui": try peer(invocation.ui), "engine": try kernel(invocation.engine),
            "receiver": try kernel(invocation.receiver), "request": try request(invocation.request, owner: owner)]
    }

    private static func engineOwner(_ invocation: ExtensionPeerServer.FixtureInvocation) throws -> String {
        guard let owner = ProcessInfo.processInfo.environment["EDITH_EXTENSION_ID"],
            HostedFunctionalActionContext.owners.contains(owner),
            invocation.receiver.executable == FunctionalHostBuild.root + "/Fixture.app/Contents/MacOS/Edith",
            invocation.receiver.birth.pid == getpid()
        else { throw FunctionalFailure.invalid("source original engine owner") }
        let endpoint = try ExtensionPeerEndpoint(namespace: FunctionalHostBuild.hostIdentifier, owner: owner,
            directory: URL(fileURLWithPath: FunctionalHostBuild.root + "/Edith Tests/worker-" + FunctionalHostBuild.session + "/ExtensionState/Commands"))
        guard invocation.endpoint == endpoint.name else {
            throw FunctionalFailure.invalid("actual original engine endpoint scope") }
        return owner
    }

    private static func engineInvocationFields(_ invocation: ExtensionPeerServer.FixtureInvocation, owner: String) throws -> [String: Any] {
        guard invocation.source.isCurrent, invocation.receiver.isCurrent,
            invocation.receiver.birth.pid == getpid(), invocation.payload.count <= 1_048_576,
            !invocation.endpoint.isEmpty, invocation.endpoint.utf8.count <= 108
        else { throw FunctionalFailure.invalid("actual engine receiver source") }
        var request: [String: Any] = ["token": invocation.token.uuidString.lowercased(),
            "operation": invocation.command, "payloadSHA256": FunctionalBytes.digest(invocation.payload),
            "payloadBytes": invocation.payload.count]
        request["payload"] = invocation.payload.base64EncodedString()
        let source = try FunctionalBirth.observe(invocation.source.birth.pid)
        let receiver = try FunctionalBirth.observe(invocation.receiver.birth.pid)
        guard invocation.source.isCurrent, invocation.receiver.isCurrent,
            source.executable == invocation.source.executable, receiver.executable == invocation.receiver.executable
        else { throw FunctionalFailure.invalid("actual engine socket identities changed") }
        return ["source": source.object, "receiver": receiver.object, "request": request,
            "endpoint": invocation.endpoint]
    }

    private static func observedReply(_ value: ExtensionEngineReply, owner: String) -> [String: Any] {
        var result: [String: Any] = ["token": value.token.uuidString.lowercased(), "ok": value.ok,
            "payloadSHA256": FunctionalBytes.digest(value.payload), "payloadBytes": value.payload.count]
        result["payload"] = value.payload.base64EncodedString()
        return result
    }

    private static func request(_ value: ExtensionEngineRequest, owner: String) throws -> [String: Any] {
        var result: [String: Any] = ["token": value.token.uuidString.lowercased(),
            "presentationID": value.presentationID.uuidString.lowercased(), "operation": value.operation,
            "timeout": value.timeout, "payloadSHA256": FunctionalBytes.digest(value.payload), "payloadBytes": value.payload.count]
        result["payload"] = value.payload.base64EncodedString()
        return result
    }

    private static func kernel(_ identity: HostRemoteKernelIdentity) throws -> [String: Any] {
        guard try HostRemoteKernelIdentity.read(identity.pid) == identity else { throw FunctionalFailure.invalid("source observed kernel changed") }
        return try FunctionalBirth.observe(identity.pid).object
    }

    private static func peer(_ identity: HostRemoteProcessIdentity) throws -> [String: Any] {
        guard try HostRemoteProcessIdentity.read(identity.pid) == identity else { throw FunctionalFailure.invalid("source observed native peer changed") }
        var result = try FunctionalBirth.observe(identity.pid).object
        result["codeHash"] = identity.codeHash.base64EncodedString()
        return result
    }

    private static func capturedKernel(_ identity: HostRemoteKernelIdentity) -> [String: Any] {
        ["pid": identity.pid, "generation": identity.generation, "executable": identity.executable.path]
    }

    private static func capturedPeer(_ identity: HostRemoteProcessIdentity) -> [String: Any] {
        ["pid": identity.pid, "generation": identity.generation, "executable": identity.executable.path,
            "codeHash": identity.codeHash.base64EncodedString()]
    }

    private static func originalOwner(_ executable: URL) throws -> String {
        let path = executable.path
        for owner in HostedFunctionalActionContext.owners {
            let prefix = FunctionalHostBuild.root + "/Edith Tests/worker-" + FunctionalHostBuild.session + "/Extensions/" + owner + "/edith-host-2/arm64/"
            if path.hasPrefix(prefix), path.hasSuffix("/" + owner + "/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith") { return owner }
        }
        throw FunctionalFailure.invalid("original source UI owner path")
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}
