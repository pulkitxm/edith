#if EDITH_FUNCTIONAL_FIXTURE
import CryptoKit
import Darwin
import WorkerFixtureSupport
#endif
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
@objc(EdithBlitzTreeExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var model: BlitzTreeModel?
    private var uiModel: BlitzTreeModel?
    private var uiClient: ExtensionEngineClient?
    private var commandDrain: Task<Void, Never>?
    private var resourceStop: Task<Void, Never>?
    private var commandsSuspended = false
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    #if EDITH_FUNCTIONAL_FIXTURE
    private var signedFixture: WorkerFixtureEngineAdmission?
    private var fixtureFiles: BlitzTreeFixtureFiles?
    #endif
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        #if EDITH_FUNCTIONAL_FIXTURE
        guard signedFixture != nil || !Self.hasFixtureIntent(request) else {
            completion(nil, "The functional fixture is unavailable."); return
        }
        #else
        guard !Self.hasFixtureIntent(request) else {
            completion(nil, "The functional fixture is unavailable."); return
        }
        #endif
        let token = (request["token"] as? String).flatMap(UUID.init(uuidString:))
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self else { throw ExtensionPeerError.unavailable }
            #if EDITH_FUNCTIONAL_FIXTURE
            if let admission = signedFixture {
                guard let token, let fixtureFiles else { throw WorkerFixtureError.invalid }
                try admission.requireCurrent()
                try fixtureFiles.validateCommand(command, payload: payload)
                let request = try admission.beginRequest(
                    token: token, operation: command, payload: payload)
                do {
                    let result = try await executeCommand(command, payload: payload)
                    try admission.completeRequest(request)
                    return result
                } catch {
                    admission.cancelRequest(request)
                    throw error
                }
            }
            #endif
            return try await executeCommand(command, payload: payload)
        }
    }

    private func executeCommand(_ command: String, payload: Data) async throws -> Data {
        guard let model = model else { throw ExtensionPeerError.unavailable }
        if command == "surface.snapshot" || command == "surface.perform" {
            return try await SurfaceCommandService.execute(
                providerID: "blitztree", command: command, payload: payload,
                snapshot: { tile in BlitzTreeSurface.snapshot(model) },
                perform: { action in
                    switch action {
                    case "choose": model.chooseFolder()
                    case "rescan":
                        guard let root = model.root else {
                            throw ExtensionPeerError.invalidRequest
                        }; model.scan(root, remember: false)
                    case "cancel": model.cancel()
                    default: throw ExtensionPeerError.invalidRequest
                    }
                })
        }
        let result = try await BlitzTreeCommands.execute(command, payload: payload, model: model)
        #if EDITH_FUNCTIONAL_FIXTURE
        if signedFixture != nil, command == "blitztree.ui.scan" || command == "blitztree.ui.trash" {
            await model.finishWork()
            if command == "blitztree.ui.trash" { await model.finishWork() }
            if let error = model.error { throw ExtensionPeerError.rejected(error) }
            return try JSONEncoder().encode(model.uiSnapshot())
        }
        #endif
        return result
    }

    private static func hasFixtureIntent(_ input: NSDictionary) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return Bundle.main.bundleIdentifier?.hasPrefix("com.pulkit.edith.tests.") == true
            || input["hostedFunctionalFixture"] != nil
            || environment["EDITH_FUNCTIONAL_FIXTURE"] != nil
            || environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
            || (input["hostIdentifier"] as? String)?.hasPrefix("com.pulkit.edith.tests.") == true
            || environment["EDITH_APPLICATION_IDENTIFIER"]?.hasPrefix("com.pulkit.edith.tests.")
                == true
            || environment["EDITH_SHARED_DEFAULTS_SUITE"]?.hasPrefix("com.pulkit.edith.tests.")
                == true
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        let drain = beginCommandDrain()
        Task { [self] in
            await drain.value
            await resourceStop?.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginCommandDrain() -> Task<Void, Never> {
        let owner = model
        let uiOwner = uiModel
        commandsSuspended = true
        _ = commands.suspend()
        if let commandDrain { return commandDrain }
        owner?.cancelPendingCommands()
        uiOwner?.cancelPendingCommands()
        if let commandDrain { return commandDrain }
        let task = Task { [self] in
            _ = await commands.suspendAndWait()
            await owner?.cancelAndWait()
            await uiOwner?.cancelAndWait()
            while let task = uiDrains.values.first { await task.value }
        }
        commandDrain = task
        return task
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        let stop = beginResourceStop()
        Task { [self] in
            await stop.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginResourceStop() -> Task<Void, Never> {
        if let resourceStop { return resourceStop }
        let owner = model
        let drain = beginCommandDrain()
        if let resourceStop { return resourceStop }
        stopUI()
        model = nil
        let task = Task { [self] in
            await drain.value
            await commands.shutdownAndWait()
            await owner?.shutdown()
            #if EDITH_FUNCTIONAL_FIXTURE
            fixtureFiles = nil
            signedFixture = nil
            #endif
        }
        resourceStop = task
        return task
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "blitztree", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            do {
                #if EDITH_FUNCTIONAL_FIXTURE
                let admitted = try WorkerFixtureEngineAdmission.current(
                    extensionID: "blitztree", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self), expectedRole: .app)
                if let signedFixture {
                    guard let admitted, admitted.descriptor == signedFixture.descriptor else {
                        throw WorkerFixtureError.invalid
                    }
                    try signedFixture.requireCurrent()
                }
                if model == nil {
                    if let admitted {
                        let files = try BlitzTreeFixtureFiles.admit(admitted)
                        let client = BlitzTreeClient { root, progress in
                            try await admitted.requireCurrent()
                            let cancellation = Progress(totalUnitCount: 0)
                            let report = try await withTaskCancellationHandler {
                                try await BlockingWork.perform {
                                    try files.scan(
                                        root: root, cancellation: cancellation, progress: progress)
                                }
                            } onCancel: {
                                cancellation.cancel()
                            }
                            try await admitted.requireCurrent()
                            return report
                        }
                        model = BlitzTreeModel(client: client) { entry, root, cancellation in
                            try await admitted.requireCurrent()
                            try await BlockingWork.perform {
                                try files.trash(entry, root: root, cancellation: cancellation)
                            }
                            try await admitted.requireCurrent()
                        }
                        fixtureFiles = files
                        signedFixture = admitted
                    } else {
                        model = BlitzTreeModel()
                    }
                } else if admitted != nil, signedFixture == nil {
                    throw WorkerFixtureError.invalid
                }
                #else
                guard !Self.hasFixtureIntent(input) else { return ["ok": false] as NSDictionary }
                if model == nil { model = BlitzTreeModel() }
                #endif
            } catch { return ["ok": false] as NSDictionary }
        case "configureUI":
            guard !commandsSuspended, uiDrains.count < 8 else {
                return ["ok": false] as NSDictionary
            }
            #if EDITH_FUNCTIONAL_FIXTURE
            do {
                let admitted = try WorkerFixtureEngineAdmission.current(
                    extensionID: "blitztree", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self), expectedRole: .app)
                guard admitted?.descriptor == signedFixture?.descriptor else {
                    return ["ok": false] as NSDictionary
                }
                try signedFixture?.requireCurrent()
            } catch { return ["ok": false] as NSDictionary }
            #else
            guard !Self.hasFixtureIntent(input) else { return ["ok": false] as NSDictionary }
            #endif
            guard let configuration = ExtensionUIConfiguration(context: input),
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            stopUI(); uiClient = client; uiModel = BlitzTreeModel(engineClient: client)
            TextEditingCommands.install()
        case "stopUI": stopUI()
        case "view":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { BlitzTreePage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            _ = beginResourceStop()
        case "status": return ["ok": true, "running": model != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func stopUI() {
        TextEditingCommands.shutdown()
        let model = uiModel; uiModel = nil
        uiClient?.invalidate(); uiClient = nil
        model?.cancelPendingCommands()
        let id = UUID()
        uiDrains[id] = Task { [self] in
            defer { uiDrains[id] = nil }
            await model?.shutdown()
        }
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}

#if EDITH_FUNCTIONAL_FIXTURE
private struct BlitzTreeFixtureMetadata: Decodable, Sendable {
    let schema: Int
    let session: String
    let phase: String
    let device: String
    let inode: String
    let uid: UInt32
    let bytes: Int
    let sha256: String
}

private final class BlitzTreeFixtureFiles: @unchecked Sendable {
    private let lock = NSLock()
    private let scanDirectory: BlitzTreeFixtureDirectory
    private let trashDirectory: BlitzTreeFixtureDirectory
    private let victim: BlitzTreeFixtureFile
    private let metadata: BlitzTreeFixtureMetadata
    private var moved = false

    private init(
        scanDirectory: BlitzTreeFixtureDirectory, trashDirectory: BlitzTreeFixtureDirectory,
        victim: BlitzTreeFixtureFile, metadata: BlitzTreeFixtureMetadata
    ) throws {
        self.scanDirectory = scanDirectory
        self.trashDirectory = trashDirectory
        self.victim = victim
        self.metadata = metadata
        try validate()
    }

    @MainActor
    static func admit(_ admission: WorkerFixtureEngineAdmission) throws -> BlitzTreeFixtureFiles {
        try admission.requireCurrent()
        guard let trust = WorkerFixtureUITrustAnchor.admitted,
            let phase = WorkerFixtureFilePhase(rawValue: admission.descriptor.phase)
        else { throw WorkerFixtureError.invalid }
        let policy = try trust.rolePolicy(owner: "blitztree")
        let scopes = try sourceScopes()
        guard policy.primaryRole == .app,
            Set(policy.operations) == [
                "blitztree.ui.scan", "blitztree.ui.snapshot", "blitztree.ui.trash",
            ],
            policy.inputs == [
                try WorkerFixtureInputScope(name: "victim-metadata", maximumBytes: 4096)
            ],
            Set(policy.outputs) == ["victim", "private-trash"],
            policy.presentations == [
                try WorkerFixturePresentationScope(location: "main", section: "blitztree")
            ],
            policy.fileScopes.count == scopes.count, scopes.allSatisfy(policy.fileScopes.contains),
            Set(admission.descriptor.inputs.map(\.name)) == ["victim-metadata"],
            Set(admission.descriptor.outputs.map(\.name)) == ["victim", "private-trash"]
        else { throw WorkerFixtureError.invalid }
        let metadataURL = try admission.inputURL(named: "victim-metadata")
        let victimURL = try admission.outputURL(named: "victim")
        let trashURL = try admission.outputURL(named: "private-trash")
        let scanURL = victimURL.deletingLastPathComponent()
        _ = try policy.validateOwnedPaths(
            [
                .init(name: "victim-metadata", path: metadataURL.path, kind: .file),
                .init(name: "scan-directory", path: scanURL.path, kind: .directory),
                .init(name: "victim", path: victimURL.path, kind: .file),
                .init(name: "private-trash", path: trashURL.path, kind: .file),
            ], owner: "blitztree", root: trust.root, session: trust.session, phase: phase)
        let data = try admission.readInput(named: "victim-metadata")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == [
                "schema", "session", "phase", "device", "inode", "uid", "bytes", "sha256",
            ]
        else { throw WorkerFixtureError.invalid }
        let metadata = try JSONDecoder().decode(BlitzTreeFixtureMetadata.self, from: data)
        guard metadata.schema == 1, metadata.session == trust.session,
            metadata.phase == phase.rawValue, metadata.uid == getuid(), metadata.bytes == 4096,
            let device = Int32(metadata.device), device >= 0, String(device) == metadata.device,
            let inode = UInt64(metadata.inode), inode > 0, String(inode) == metadata.inode,
            metadata.sha256.utf8.count == 64,
            metadata.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw WorkerFixtureError.invalid }
        let scanDirectory = try BlitzTreeFixtureDirectory(scanURL)
        let trashDirectory = try BlitzTreeFixtureDirectory(trashURL.deletingLastPathComponent())
        let victim = try BlitzTreeFixtureFile(directory: scanDirectory)
        let files = try BlitzTreeFixtureFiles(
            scanDirectory: scanDirectory, trashDirectory: trashDirectory,
            victim: victim, metadata: metadata)
        try admission.requireCurrent()
        return files
    }

    private static func sourceScopes() throws -> [WorkerFixtureFileScope] {
        [
            try WorkerFixtureFileScope(
                name: "victim-metadata", kind: .file, purpose: .immutableInput, root: .ownerInputs,
                components: [.phase, .literal("victim.json")], maximumBytes: 4096,
                maximumEntries: 1,
                initialState: .present, allowedStates: [.present], immutableFiles: [],
                mutableFiles: []),
            try WorkerFixtureFileScope(
                name: "scan-directory", kind: .directory, purpose: .mutableState,
                root: .ownerOutputs,
                components: [.phase, .literal("scan")], maximumBytes: 4096, maximumEntries: 1,
                initialState: .present, allowedStates: [.present], immutableFiles: [],
                mutableFiles: [
                    try WorkerFixtureMutableFileScope(
                        components: ["victim.bin"], maximumBytes: 4096, initialState: .present,
                        allowedStates: [.present, .absent])
                ]),
            try WorkerFixtureFileScope(
                name: "victim", kind: .file, purpose: .mutableState, root: .ownerOutputs,
                components: [.phase, .literal("scan"), .literal("victim.bin")],
                maximumBytes: 4096, maximumEntries: 1, initialState: .present,
                allowedStates: [.present, .absent], immutableFiles: [], mutableFiles: []),
            try WorkerFixtureFileScope(
                name: "private-trash", kind: .file, purpose: .initiallyAbsentOutput,
                root: .ownerOutputs,
                components: [.phase, .literal("trash"), .literal("victim.bin")],
                maximumBytes: 4096, maximumEntries: 1, initialState: .absent,
                allowedStates: [.absent, .present], immutableFiles: [], mutableFiles: []),
        ]
    }

    func validateCommand(_ command: String, payload: Data) throws {
        try lock.withLock {
            try validate()
            if command == "blitztree.ui.snapshot" {
                guard payload == Data("{}".utf8) else { throw WorkerFixtureError.invalid }
                return
            }
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else {
                throw WorkerFixtureError.invalid
            }
            switch command {
            case "blitztree.ui.scan":
                guard Set(object.keys) == ["path"],
                    object["path"] as? String == scanDirectory.url.path
                else {
                    throw WorkerFixtureError.invalid
                }
            case "blitztree.ui.trash":
                guard !moved, Set(object.keys) == ["confirmed", "previewToken", "path"],
                    object["path"] as? String
                        == scanDirectory.url.appendingPathComponent("victim.bin").path
                else { throw WorkerFixtureError.invalid }
            default: throw WorkerFixtureError.invalid
            }
        }
    }

    func scan(root: String, cancellation: Progress, progress: @escaping BlitzTreeClient.Progress)
        throws -> BlitzTreeReport
    {
        try lock.withLock {
            guard root == scanDirectory.url.path else { throw WorkerFixtureError.invalid }
            try validate()
            let report = try BlitzTreeScanner.scan(
                root: root, isCancelled: { cancellation.isCancelled }, progress: progress)
            try validate()
            guard report.root == root, report.coverage.complete, report.coverage.errors == 0,
                report.summary.fileCount == (moved ? 0 : 1), report.summary.directoryCount == 1
            else { throw WorkerFixtureError.invalid }
            return report
        }
    }

    func trash(_ entry: BlitzTreeReport.Entry, root: String, cancellation: Progress) throws {
        try lock.withLock {
            guard !moved, root == scanDirectory.url.path, entry.kind == "file",
                entry.logicalBytes == 4096,
                entry.path == scanDirectory.url.appendingPathComponent("victim.bin").path,
                String(entry.device) == metadata.device, String(entry.inode) == metadata.inode
            else { throw WorkerFixtureError.invalid }
            try validate()
            try BlitzTreeActions.trash(entry, root: root, isCancelled: { cancellation.isCancelled })
            { url in
                guard url.path == entry.path else { throw WorkerFixtureError.invalid }
                try validate()
                guard
                    renameatx_np(
                        scanDirectory.descriptor, "victim.bin", trashDirectory.descriptor,
                        "victim.bin",
                        UInt32(RENAME_EXCL)) == 0
                else { throw WorkerFixtureError.invalid }
                moved = true
                try validate()
            }
        }
    }

    private func validate() throws {
        try scanDirectory.validate()
        try trashDirectory.validate()
        guard try scanDirectory.names() == (moved ? [] : ["victim.bin"]),
            try trashDirectory.names() == (moved ? ["victim.bin"] : [])
        else { throw WorkerFixtureError.invalid }
        var state = stat()
        let current = moved ? trashDirectory : scanDirectory
        let absent = moved ? scanDirectory : trashDirectory
        guard fstatat(current.descriptor, "victim.bin", &state, AT_SYMLINK_NOFOLLOW) == 0,
            state.st_mode & S_IFMT == S_IFREG, state.st_mode & 0o777 == 0o600,
            state.st_nlink == 1, state.st_uid == metadata.uid, state.st_size == 4096,
            String(state.st_dev) == metadata.device, String(state.st_ino) == metadata.inode,
            fstatat(absent.descriptor, "victim.bin", &state, AT_SYMLINK_NOFOLLOW) == -1,
            errno == ENOENT
        else { throw WorkerFixtureError.invalid }
        try victim.validate(metadata: metadata)
        try scanDirectory.validate()
        try trashDirectory.validate()
    }
}

private final class BlitzTreeFixtureDirectory: @unchecked Sendable {
    let url: URL
    let descriptor: Int32
    private let identity: stat

    init(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkerFixtureError.invalid }
        var identity = stat()
        guard fstat(descriptor, &identity) == 0, identity.st_mode & S_IFMT == S_IFDIR,
            identity.st_mode & 0o777 == 0o700, identity.st_uid == getuid()
        else { close(descriptor); throw WorkerFixtureError.invalid }
        self.url = url
        self.descriptor = descriptor
        self.identity = identity
    }

    deinit { close(descriptor) }

    func validate() throws {
        var opened = stat(); var current = stat()
        guard fstat(descriptor, &opened) == 0, lstat(url.path, &current) == 0,
            opened.st_dev == identity.st_dev, opened.st_ino == identity.st_ino,
            current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
            opened.st_uid == getuid(), current.st_uid == getuid(),
            opened.st_mode & S_IFMT == S_IFDIR, current.st_mode & S_IFMT == S_IFDIR,
            opened.st_mode & 0o777 == 0o700, current.st_mode & 0o777 == 0o700
        else { throw WorkerFixtureError.invalid }
    }

    func names() throws -> Set<String> {
        try validate()
        let duplicated = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard duplicated >= 0 else { throw WorkerFixtureError.invalid }
        guard let directory = fdopendir(duplicated) else {
            close(duplicated); throw WorkerFixtureError.invalid
        }
        defer { closedir(directory) }
        var names: Set<String> = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            guard name == "." || name == ".." || name == "victim.bin" else {
                throw WorkerFixtureError.invalid
            }
            if name != ".", name != ".." { names.insert(name) }
            errno = 0
        }
        guard errno == 0 else { throw WorkerFixtureError.invalid }
        return names
    }
}

private final class BlitzTreeFixtureFile: @unchecked Sendable {
    private let descriptor: Int32

    init(directory: BlitzTreeFixtureDirectory) throws {
        let descriptor = openat(
            directory.descriptor, "victim.bin", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw WorkerFixtureError.invalid }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    func validate(metadata: BlitzTreeFixtureMetadata) throws {
        var state = stat()
        guard fstat(descriptor, &state) == 0, state.st_mode & S_IFMT == S_IFREG,
            state.st_mode & 0o777 == 0o600, state.st_uid == metadata.uid, state.st_nlink == 1,
            state.st_size == 4096, String(state.st_dev) == metadata.device,
            String(state.st_ino) == metadata.inode
        else { throw WorkerFixtureError.invalid }
        var data = Data(count: 4096)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = pread(
                    descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset,
                    off_t(offset))
                guard count > 0 else { throw WorkerFixtureError.invalid }
                offset += count
            }
        }
        guard
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.sha256
        else {
            throw WorkerFixtureError.invalid
        }
    }
}
#endif
