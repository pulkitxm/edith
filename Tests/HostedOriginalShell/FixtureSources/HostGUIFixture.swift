#if EDITH_GUI_FIXTURE
import AppKit
import CryptoKit
import Darwin
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import Foundation
import SwiftUI

@MainActor enum HostGUIFixture {
    static var environmentVisible = false
    static private(set) var declinedPermissionRequests = 0

    static func permissionRequestDeclined() { declinedPermissionRequests += 1 }
    static private(set) var fixture: JourneyFixture?
    private static var telemetry: Task<Void, Never>?
    private static var processes = JourneyProcessRegistry()
    private static weak var remoteManager: HostRemoteSessionManager?

    static func make() throws -> HostMarketplace {
        do {
            let marketplace = try makeValidated()
            try recordProducer(phase: "make")
            return marketplace
        } catch {
            try? recordProducer(phase: "make", error: error)
            throw error
        }
    }

    private static func makeValidated() throws -> HostMarketplace {
        let environment = ProcessInfo.processInfo.environment
        let account = try accountHome()
        guard let identifier = Bundle.main.bundleIdentifier,
            identifier.hasPrefix("com.pulkit.edith.tests.remote-"),
            let suffix = identifier.split(separator: ".").last,
            UUID(uuidString: String(suffix.dropFirst("remote-".count))) != nil
        else { throw JourneyContractError.invalidIdentity }
        let uuid = String(identifier.dropFirst("com.pulkit.edith.tests.remote-".count))
        let directory = URL(
            fileURLWithPath: account + "/Applications/Edith Remote Fixture Journey " + uuid)
        guard environment["EDITH_GUI_FIXTURE_DIRECTORY"] == directory.path,
            environment["GITHUB_ACTIONS"] == "true",
            environment["RUNNER_ENVIRONMENT"] == "github-hosted",
            environment["EDITH_HOSTED_SHELL_JOURNEY"] == "1"
        else { throw JourneyContractError.untrustedRunner }
        try requireOwned(directory, directory: true, mode: 0o700)
        let value = try JSONDecoder().decode(
            JourneyFixture.self,
            from: read(directory.appendingPathComponent("journey.json"), limit: 16_384))
        try value.validate(accountHome: account, environment: environment)
        try value.validateApplicationEnvironment(environment)
        guard value.identifier == identifier, value.directory == directory.path,
            Bundle.main.bundleURL.path == value.application,
            Bundle.main.executableURL?.path == value.executable,
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            value.executableSHA256[appVersion]
                == (try digest(URL(fileURLWithPath: value.executable)))
        else { throw JourneyContractError.invalidMetadata }
        for path in [value.home, value.support] {
            try requireOwned(URL(fileURLWithPath: path), directory: true, mode: 0o700)
        }
        try verifyProtected(value)
        fixture = value
        let identity = try HostIdentity(
            identifier: identifier, supportDirectory: URL(fileURLWithPath: value.support))
        guard identity.root.path == value.identityRoot else {
            throw JourneyContractError.invalidPaths
        }
        let packages = try JSONDecoder().decode(
            [ExtensionPackage].self,
            from: read(directory.appendingPathComponent("packages.json"), limit: 65_536))
        guard packages.count == 2, packages.map(\.version) == value.versions,
            packages.allSatisfy({
                $0.id == "calendar" && $0.hostABI == HostContract.compatibility
                    && $0.architecture == "arm64" && $0.dependencies.isEmpty
            }),
            Set(packages.map(\.downloadURL)).count == 2
        else { throw JourneyContractError.invalidMetadata }
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        let publicKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 90, count: 32)
        ).publicKey.rawRepresentation
        let client = ExtensionCatalogClient(
            url: URL(
                string:
                    "https://github.com/pulkitxm/edith/releases/download/hosted-shell-fixture/catalog.json"
            )!,
            publicKey: publicKey, repository: MarketplaceConfiguration.repository,
            cache: identity.root.appendingPathComponent("catalog.json"),
            fetch: { _ in
                try verifyProtected(value)
                return try read(
                    directory.appendingPathComponent("active-catalog.json"), limit: 3_145_728)
            })
        let installer = ExtensionPackageInstaller(
            store: store,
            download: { url, count in
                try verifyProtected(value)
                guard let package = packages.first(where: { $0.downloadURL == url }),
                    count == package.downloadBytes
                else { throw MarketplaceError.downloadFailed }
                let archive = directory.appendingPathComponent(
                    "archives/calendar-" + package.version + ".zip")
                try requireOwned(archive, directory: false)
                guard try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(count),
                    (try digest(archive)) == package.sha256
                else { throw MarketplaceError.downloadFailed }
                let temporary = directory.appendingPathComponent(
                    "downloads/" + UUID().uuidString + ".zip")
                try FileManager.default.copyItem(at: archive, to: temporary)
                return temporary
            },
            verify: { payload in
                let manifest = try JSONDecoder().decode(
                    ExtensionPayloadManifest.self,
                    from: read(payload.appendingPathComponent("package.json"), limit: 16_384))
                guard manifest.id == "calendar", value.versions.contains(manifest.version),
                    manifest.hostABI == HostContract.compatibility
                else { throw MarketplaceError.invalidBundle }
                let carrier = try ExtensionUICarrier(
                    payload: payload, manifest: manifest, expectedHostIdentifier: value.identifier)
                guard carrier.hostExecutablePath == value.executable else {
                    throw MarketplaceError.invalidBundle
                }
                try carrier.verifyDevelopment()
                for role in try FileManager.default.contentsOfDirectory(
                    at: carrier.payloadDirectory, includingPropertiesForKeys: nil)
                where role.pathExtension == "bundle" {
                    try ExtensionCodeSignature.verifyDevelopment(role)
                }
            })
        guard let defaults = UserDefaults(suiteName: identity.defaultsSuite) else {
            throw JourneyContractError.invalidEnvironment
        }
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            try verifyProtected(value)
            try prepareCalendar(value, identity: identity, store: store, package: package)
            return HostWorker(
                configuration: HostWorkerConfiguration(
                    identity: identity, extensionID: package.id, version: package.version),
                executable: URL(fileURLWithPath: value.executable), errorOutput: .standardError)
        }
        let marketplace = try HostMarketplace(
            identity: identity, entries: HostIndex.bundled(), store: store, catalogClient: client,
            installer: installer, sessions: sessions)
        marketplace.automaticallyUpdatesExtensions = false
        telemetry = Task { [weak marketplace] in
            while !Task.isCancelled {
                guard let marketplace else { return }
                do {
                    try writeState(marketplace, fixture: value)
                    try recordProducer(phase: "telemetry")
                } catch {
                    try? recordProducer(phase: "telemetry", error: error)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        return marketplace
    }

    static func bind(_ manager: HostRemoteSessionManager) {
        remoteManager = manager
    }

    static func recordUI(_ handle: HostRemoteSceneHandle) throws {
        guard let fixture, handle.request.extensionID == "calendar",
            let peer = handle.processIdentity, peer.isRunning,
            peer.executable.path.hasPrefix(fixture.identityRoot + "/Extensions/calendar/")
        else { throw JourneyContractError.invalidMetadata }
        try processes.register(
            role: "managedUI", identity: processIdentity(peer.pid),
            expectedExecutable: peer.executable.path)
    }

    private static func processIdentity(_ pid: Int32) throws -> JourneyProcessRegistry.Identity {
        let identity = try HostRemoteKernelIdentity.read(pid)
        return .init(
            pid: identity.pid, generation: identity.generation, executable: identity.executable.path
        )
    }

    private static func residentBytes(_ pid: Int32) -> UInt64? {
        var info = proc_taskinfo()
        let count = MemoryLayout<proc_taskinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(count)) == count else {
            return nil
        }
        return info.pti_resident_size
    }

    static func stop() async {
        telemetry?.cancel()
        await telemetry?.value
        telemetry = nil
    }

    private static func prepareCalendar(
        _ value: JourneyFixture, identity: HostIdentity, store: ExtensionPackageStore,
        package: ExtensionPackage
    ) throws {
        guard package.id == "calendar", value.versions.contains(package.version) else {
            throw JourneyContractError.invalidMetadata
        }
        let packageDirectory = store.directory(for: package).appendingPathComponent("calendar")
        try requireOwned(packageDirectory, directory: true)
        let marker: [String: Any] = [
            "schema": 1, "hostIdentifier": value.identifier,
            "dataDirectory": identity.extensionDirectory("calendar").path,
            "packageDirectory": packageDirectory.path,
        ]
        let path = URL(fileURLWithPath: value.home).appendingPathComponent("calendar-fixture.json")
        let data = try JSONSerialization.data(withJSONObject: marker, options: .sortedKeys)
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        try requireOwned(path, directory: false, mode: 0o600)
    }

    private static func writeState(_ marketplace: HostMarketplace, fixture: JourneyFixture) throws {
        try verifyProtected(fixture)
        try processes.register(
            role: "host", identity: processIdentity(getpid()),
            expectedExecutable: fixture.executable)
        for pid in marketplace.sessions.processIdentifiers.values {
            if let identity = try? processIdentity(pid) {
                try processes.register(
                    role: "engine", identity: identity, expectedExecutable: fixture.executable)
            }
        }
        let observed = processes.observations(
            identity: { try? processIdentity($0) }, residentBytes: residentBytes)
        let processData = try JSONSerialization.jsonObject(with: JSONEncoder().encode(observed))
        let home = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(marketplace.surfaceLayouts.home))
        let notch = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(marketplace.surfaceLayouts.notch))
        let state: [String: Any] = [
            "schema": 1,
            "producerExecutableSHA256": try digest(URL(fileURLWithPath: fixture.executable)),
            "hostIdentifier": fixture.identifier, "sourceCommit": fixture.sourceCommit,
            "applicationVersion": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "downloaded": marketplace.downloadedIDs.sorted(),
            "active": marketplace.surfaceAvailability.activeIDs.sorted(),
            "workers": marketplace.sessions.processIdentifiers,
            "versions": marketplace.sessions.versions,
            "error": marketplace.error ?? "", "home": home, "notch": notch,
            "visibleHome": marketplace.surfaceAvailability.projected(
                marketplace.surfaceLayouts.home, target: .home
            ).tiles.map(\.id),
            "visibleNotch": marketplace.surfaceAvailability.projected(
                marketplace.surfaceLayouts.notch, target: .notch
            ).tiles.map(\.id),
            "protectedDataUnchanged": true,
            "ownedProcesses": processData,
            "presentationCounts": remoteManager?.presentationCounts() ?? [:],
            "declinedPermissionRequests": declinedPermissionRequests,
        ]
        let data = try JSONSerialization.data(withJSONObject: state, options: .sortedKeys)
        guard data.count <= 131_072 else { throw JourneyContractError.invalidMetadata }
        try data.write(
            to: URL(fileURLWithPath: fixture.directory).appendingPathComponent("state.json"),
            options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fixture.directory + "/state.json")
    }

    private static func recordProducer(phase: String, error: (any Error)? = nil) throws {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let prefix = "com.pulkit.edith.tests.remote-"
        let suffix = String(identifier.dropFirst(prefix.count))
        guard identifier.hasPrefix(prefix),
            UUID(uuidString: suffix)?.uuidString.lowercased() == suffix
        else { return }
        let directory = URL(
            fileURLWithPath: try accountHome() + "/Applications/Edith Remote Fixture Journey "
                + suffix)
        guard ProcessInfo.processInfo.environment["EDITH_GUI_FIXTURE_DIRECTORY"] == directory.path
        else { return }
        try requireOwned(directory, directory: true, mode: 0o700)
        let value = try JSONDecoder().decode(
            JourneyFixture.self,
            from: read(directory.appendingPathComponent("journey.json"), limit: 16_384))
        guard value.identifier == identifier, value.directory == directory.path else { return }
        try value.validate(
            accountHome: try accountHome(), environment: ProcessInfo.processInfo.environment)
        let bytes = try JSONEncoder().encode(
            JourneyProducerReceipt(
                fixture: value, phase: phase, error: error,
                environment: ProcessInfo.processInfo.environment))
        guard bytes.count <= 1024 else { throw JourneyContractError.invalidMetadata }
        let path = directory.appendingPathComponent("producer.json")
        try bytes.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    nonisolated private static func read(_ url: URL, limit: Int) throws -> Data {
        try requireOwned(url, directory: false)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit
        else { throw JourneyContractError.invalidMetadata }
        return data
    }

    nonisolated private static func digest(_ url: URL) throws -> String {
        try requireOwned(url, directory: false)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func verifyProtected(_ fixture: JourneyFixture) throws {
        var actual: [String: String] = [:]
        for path in fixture.protectedRelativePaths {
            actual[path] = try digest(
                URL(fileURLWithPath: fixture.directory).appendingPathComponent(path))
        }
        try fixture.verifyProtectedDigests(actual)
    }

    nonisolated private static func requireOwned(_ url: URL, directory: Bool, mode: Int? = nil)
        throws
    {
        guard url.path == url.standardizedFileURL.path,
            url.path == url.resolvingSymlinksInPath().path
        else { throw JourneyContractError.invalidPaths }
        let value = try FileManager.default.attributesOfItem(atPath: url.path)
        guard value[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
            (value[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            let permissions = value[.posixPermissions] as? NSNumber,
            permissions.intValue & 0o022 == 0, mode == nil || permissions.intValue == mode
        else { throw JourneyContractError.invalidPaths }
    }

    nonisolated private static func accountHome() throws -> String {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        return try buffer.withUnsafeMutableBufferPointer {
            guard getpwuid_r(getuid(), &record, $0.baseAddress, $0.count, &result) == 0,
                result != nil, record.pw_uid == getuid(), let path = record.pw_dir
            else { throw JourneyContractError.invalidPaths }
            return String(cString: path)
        }
    }
}

struct HostGUIVisibilityProbe: View {
    @Environment(\.windowVisible) private var visible
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { HostGUIFixture.environmentVisible = visible }
            .onChange(of: visible) { HostGUIFixture.environmentVisible = visible }
    }
}
#endif
