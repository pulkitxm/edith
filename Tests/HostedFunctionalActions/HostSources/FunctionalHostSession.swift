import AppKit
import CryptoKit
import Darwin
import EdithExtensionSupport
import EdithHostCore
import ExtensionFoundation
import ExtensionKit
import ExtensionMarketplace
import Foundation

@MainActor
final class FunctionalHostSession: NSObject, EXHostViewControllerDelegate {
    let owner: String
    let identity: HostIdentity
    private let root: FunctionalPinnedPath
    private let marketplace: HostMarketplace
    private let manager: HostRemoteSessionManager
    private let packages: [ExtensionPackage]
    private let archives: [String: FunctionalPinnedPath]
    private var activeCatalog: Data
    private var generation: HostRemoteSceneHandle?
    private var remote: EXHostViewController?
    private var window: NSWindow?
    private var phase: String?
    private var engineBirth: FunctionalBirth?
    private var uiBirth: FunctionalBirth?
    private var closed = false
    private var busy = false
    private var connecting: Task<Void, any Error>?
    private var startingRequest: HostExtensionContentRequest?

    init(owner: String, packages: [ExtensionPackage], catalog: Data, archives: [String: FunctionalPinnedPath], root: FunctionalPinnedPath) throws {
        guard HostedFunctionalActionContext.owners.contains(owner), packages.count == 2,
            packages.map(\.version) == ["1.0.0", "1.1.0"],
            packages.allSatisfy({ $0.id == owner && $0.hostABI == "edith-host-2" && $0.architecture == "arm64" && $0.dependencies.isEmpty }),
            Set(archives.keys) == Set(packages.map(\.version))
        else { throw FunctionalFailure.invalid("source-built package pair") }
        for package in packages {
            try package.validate(repository: "pulkitxm/edith")
            guard let archive = archives[package.version],
                archive.url.path == root.url.path + "/packages-" + owner + "-" + package.version + "/" + owner + ".zip",
                try FunctionalBytes.digest(archive.read()) == package.sha256
            else { throw FunctionalFailure.invalid("source-built package archive") }
        }
        try root.requireCurrent()
        self.owner = owner
        self.root = root
        self.packages = packages
        self.archives = archives
        activeCatalog = catalog
        identity = try HostIdentity(identifier: FunctionalHostBuild.hostIdentifier, supportDirectory: root.url)
        guard identity.root.path == root.url.path + "/Edith Tests/worker-" + FunctionalHostBuild.session,
            let executable = Bundle.main.executableURL,
            executable.path == root.url.path + "/Fixture.app/Contents/MacOS/Edith",
            let defaults = UserDefaults(suiteName: identity.defaultsSuite)
        else { throw FunctionalFailure.invalid("original Host identity") }
        let sourceIdentity = identity
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        let client = ExtensionCatalogClient(url: MarketplaceConfiguration.catalogURL,
            publicKey: FunctionalHostBuild.issuerPublicKey, repository: "pulkitxm/edith",
            cache: identity.root.appendingPathComponent("catalog.json"),
            fetch: { _ in throw FunctionalFailure.unavailable("unconfigured source-bound catalog") })
        let installer = ExtensionPackageInstaller(store: store,
            download: { url, count in
                try root.requireCurrent()
                guard let package = packages.first(where: { $0.downloadURL == url }),
                    package.downloadBytes == count, let archive = archives[package.version],
                    try FunctionalBytes.digest(archive.read()) == package.sha256
                else { throw MarketplaceError.downloadFailed }
                let temporary = root.url.appendingPathComponent("downloads/" + UUID().uuidString.lowercased() + ".zip")
                try FileManager.default.copyItem(at: archive.url, to: temporary)
                return temporary
            },
            verify: { payload in
                let manifestBytes = try FunctionalPinnedPath(payload.appendingPathComponent("package.json"), directory: false, maximum: 65536).read()
                let manifest = try JSONDecoder().decode(ExtensionPayloadManifest.self, from: manifestBytes)
                guard manifest.id == owner, ["1.0.0", "1.1.0"].contains(manifest.version),
                    manifest.hostABI == "edith-host-2", manifest.architecture == "arm64"
                else { throw MarketplaceError.invalidBundle }
                let carrier = try ExtensionUICarrier(payload: payload, manifest: manifest,
                    expectedHostIdentifier: FunctionalHostBuild.hostIdentifier)
                guard carrier.hostExecutablePath == executable.path else { throw MarketplaceError.invalidBundle }
                try carrier.verifyDevelopment()
                let worker = carrier.worker
                try FunctionalSigner(identifier: FunctionalHostBuild.hostIdentifier + ".extension." + owner + ".worker",
                    certificateSHA256: FunctionalHostBuild.certificateSHA256,
                    requirement: "identifier \"" + FunctionalHostBuild.hostIdentifier + ".extension." + owner + ".worker\"")
                    .verify(worker)
                for role in try FileManager.default.contentsOfDirectory(at: carrier.payloadDirectory, includingPropertiesForKeys: nil)
                where role.pathExtension == "bundle" {
                    guard ["app", "agent", "helper"].contains(role.deletingPathExtension().lastPathComponent)
                    else { throw MarketplaceError.invalidBundle }
                    try FunctionalSigner(identifier: "com.pulkit.edith.extensions." + owner + "." + role.deletingPathExtension().lastPathComponent,
                        certificateSHA256: FunctionalHostBuild.certificateSHA256,
                        requirement: "identifier \"com.pulkit.edith.extensions." + owner + "." + role.deletingPathExtension().lastPathComponent + "\"")
                        .verify(role)
                }
            })
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            HostWorker(configuration: HostWorkerConfiguration(identity: sourceIdentity,
                extensionID: package.id, version: package.version), executable: executable)
        }
        marketplace = try HostMarketplace(identity: identity, entries: HostIndex.bundled(), store: store,
            catalogClient: client, installer: installer, sessions: sessions)
        manager = HostRemoteSessionManager(marketplace: marketplace)
        super.init()
        manager.detach = { [weak self] id in
            guard self?.owner == id else { return }
            self?.remote?.configuration = nil
            self?.window?.orderOut(nil)
        }
    }

    func selectCatalog(_ bytes: Data) async throws {
        guard !busy, !closed, generation == nil else { throw FunctionalFailure.invalid("catalog lifecycle order") }
        try root.requireCurrent()
        let envelope = try JSONDecoder().decode(SignedExtensionCatalog.self, from: bytes)
        let catalog = try envelope.verified(publicKey: FunctionalHostBuild.issuerPublicKey, repository: "pulkitxm/edith")
        guard catalog.packages.count == 1, packages.contains(catalog.packages[0])
        else { throw FunctionalFailure.invalid("selected source package catalog") }
        activeCatalog = bytes
        let cache = identity.root.appendingPathComponent("catalog.json")
        try bytes.write(to: cache, options: .atomic)
        await marketplace.loadCachedCatalog()
        guard marketplace.error == nil, marketplace.available[owner] == catalog.packages[0]
        else { throw FunctionalFailure.invalid("original catalog admission") }
    }

    func install(version: String) async throws {
        guard !busy, !closed, generation == nil,
            let package = packages.first(where: { $0.version == version }),
            marketplace.available[owner] == package
        else { throw FunctionalFailure.invalid("original install selection") }
        busy = true
        defer { busy = false }
        await marketplace.download(id: owner, expectedPackage: package)
        guard marketplace.error == nil, marketplace.installed[owner] == package,
            marketplace.downloadedIDs.contains(owner), !marketplace.pendingRemovalIDs.contains(owner)
        else { throw FunctionalFailure.invalid("original installer outcome") }
    }

    func openOriginal(phase: String, location: String, section: String, presentationID: UUID) async throws -> HostRemoteSceneHandle {
        guard !busy, !closed, generation == nil, ["initial", "updated", "reinstalled"].contains(phase),
            let package = marketplace.installed[owner], package.version == (phase == "initial" ? "1.0.0" : "1.1.0")
        else { throw FunctionalFailure.invalid("original generation phase") }
        busy = true
        defer { busy = false }
        try root.requireCurrent()
        self.phase = phase
        let request = HostExtensionContentRequest(extensionID: owner,
            location: location, section: section, presentationID: presentationID)
        startingRequest = request
        defer { startingRequest = nil }
        try await marketplace.sessions.enable(package)
        guard let enginePID = marketplace.sessions.processIdentifiers[owner] else { throw FunctionalFailure.invalid("original engine birth") }
        let engine = try FunctionalBirth.observe(enginePID)
        let handle = try await manager.scene(for: request)
        self.phase = phase
        generation = handle
        engineBirth = engine
        let remote = EXHostViewController()
        remote.delegate = self
        remote.configuration = EXHostViewController.Configuration(appExtension: handle.identity, sceneID: handle.sceneIdentifier)
        let window = NSWindow(contentViewController: remote)
        window.title = "Synthetic functional " + owner + " " + phase + " " + FunctionalHostBuild.session
        window.setContentSize(NSSize(width: 1000, height: 720))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        self.remote = remote
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !handle.isPresented {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw FunctionalFailure.timeout("original downloaded UI admission") }
            try engine.requireCurrent()
            try await Task.sleep(for: .milliseconds(50))
        }
        if let connecting { try await connecting.value }
        guard let ui = handle.processIdentity else { throw FunctionalFailure.invalid("authenticated original UI birth") }
        uiBirth = try FunctionalBirth.observe(ui.pid)
        return handle
    }

    func prepareStartingWorker(_ worker: HostWorker, birth: ExtensionProcessIdentity) async throws {
        guard busy, !closed, generation == nil, let phase, let request = startingRequest,
            worker.configuration.extensionID == owner,
            worker.configuration.identifier == identity.identifier,
            worker.configuration.supportDirectory.path == root.url.path,
            birth.pid == worker.processIdentifier, birth.isAlive,
            worker.configuration.version == (phase == "initial" ? "1.0.0" : "1.1.0")
        else { throw FunctionalFailure.invalid("original preconfiguration reservation") }
        try root.requireCurrent()
        let engine = try FunctionalBirth.observe(birth.pid)
        let session = try await manager.fixturePrepareStartingWorker(worker: worker, birth: birth, request: request)
        let ui = try await session.fixturePrepareNativePeer()
        guard try FunctionalBytes.canonical(JSONSerialization.jsonObject(with: JSONEncoder().encode(session.configuration.worker)))
                == FunctionalBytes.canonical(JSONSerialization.jsonObject(with: JSONEncoder().encode(worker.configuration))),
            session.engineIdentity == (try HostRemoteKernelIdentity.read(birth.pid))
        else { throw FunctionalFailure.invalid("same original prepared reservation") }
        let observedUI = try FunctionalBirth.observe(ui.pid)
        _ = try FunctionalHostBootstrap.rendezvous(operation: "prepared-original-peers", owner: owner, phase: phase,
            fields: ["configuration": try JSONSerialization.jsonObject(with: JSONEncoder().encode(session.configuration)),
                "request": try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)),
                "engine": engine.object, "ui": observedUI.object])
        try engine.requireCurrent()
        try observedUI.requireCurrent()
        try root.requireCurrent()
    }

    func hostViewControllerDidActivate(_ viewController: EXHostViewController) {
        guard viewController === remote, let handle = generation else { return }
        guard connecting == nil else { return }
        connecting = Task { @MainActor in
            try await handle.connect(through: viewController.makeXPCConnection(), compact: false, visible: true, width: 1000)
        }
    }

    func closeAndDrain() async throws -> [String: Any] {
        guard !busy, !closed, let handle = generation, let engine = engineBirth, let ui = uiBirth
        else { throw FunctionalFailure.invalid("owned original drain order") }
        busy = true
        defer { busy = false }
        if let connecting { try await connecting.value }
        try await handle.prepareToClose()
        try await HostRemoteSession.fixtureStopAllWithoutEscalation(extensionID: owner)
        window?.orderOut(nil)
        remote?.configuration = nil
        try await handle.close()
        try await marketplace.sessions.disable(id: owner)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while true {
            do { try engine.requireAbsent(); try ui.requireAbsent(); break }
            catch {
                guard ContinuousClock.now < deadline else { throw FunctionalFailure.timeout("natural original owned births") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        guard !marketplace.sessions.activeIDs.contains(owner), marketplace.sessions.processIdentifiers[owner] == nil,
            !HostRemoteSession.extensionIDs.contains(owner)
        else { throw FunctionalFailure.invalid("original sessions still held") }
        generation = nil
        connecting = nil
        engineBirth = nil
        uiBirth = nil
        window?.contentViewController = nil
        remote = nil
        window = nil
        for package in packages {
            let lease = try PackageFileLock(url: marketplace.packageStore.leaseURL(for: package), exclusive: true)
            lease.close()
        }
        return ["births": [engine.contractObject, ui.contractObject], "birthsAbsent": true,
            "leasesReleased": true, "sourceOwnedDrainReceiptRequired": true]
    }

    func remove() async throws -> [String] {
        guard !busy, !closed, generation == nil, engineBirth == nil, uiBirth == nil else { throw FunctionalFailure.invalid("original removal order") }
        busy = true
        defer { busy = false }
        await marketplace.remove(id: owner)
        guard marketplace.error == nil, !marketplace.downloadedIDs.contains(owner),
            !marketplace.pendingRemovalIDs.contains(owner), marketplace.installedVersions[owner] == nil,
            try !marketplace.packageStore.pendingRemovals().contains(owner)
        else { throw FunctionalFailure.invalid("original removal completion") }
        for package in packages {
            guard !FileManager.default.fileExists(atPath: marketplace.packageStore.directory(for: package).path)
            else { throw FunctionalFailure.invalid("retained version physically present") }
        }
        return packages.map(\.version)
    }

    func stop() async throws {
        if generation != nil { _ = try await closeAndDrain() }
        guard await marketplace.sessions.shutdown(), !HostRemoteSession.extensionIDs.contains(owner)
        else { throw FunctionalFailure.invalid("original Host session shutdown") }
        closed = true
    }
}
