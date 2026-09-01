import Darwin
import Dispatch
import Foundation
import MachO
import Security

enum DatabaseBrokerExecutableLauncherError: Error, Equatable, Sendable {
    case executablePathUnavailable
    case executablePathInvalid
    case executableCanonicalizationFailed
    case executableOpenFailed
    case executableMetadataUnavailable
    case executableUnsafe
    case executableReplaced
    case currentCodeUnavailable
    case currentStaticCodeUnavailable
    case currentDesignatedRequirementUnavailable
    case currentCodeInvalid
    case currentUniqueIdentifierUnavailable
    case candidateStaticCodeUnavailable
    case candidateCodeInvalid
    case candidateUniqueIdentifierUnavailable
    case candidateUniqueIdentifierMismatch
    case spawnConfigurationFailed
    case spawnFailed
}

enum DatabaseBrokerExecutableLaunchLeaseError: Error, Equatable, Sendable {
    case notPermitted
}

final class DatabaseBrokerExecutableLaunchLease: @unchecked Sendable {
    private enum State {
        case active
        case revoked
        case committed
        case failed
    }

    private let stateLock = NSLock()
    private let deadlineNanoseconds: UInt64
    private let monotonicNanoseconds: @Sendable () -> UInt64
    private var state = State.active

    init(
        deadlineNanoseconds: UInt64,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64
    ) {
        self.deadlineNanoseconds = deadlineNanoseconds
        self.monotonicNanoseconds = monotonicNanoseconds
    }

    var isCommitted: Bool {
        stateLock.withLock {
            if case .committed = state {
                return true
            }
            return false
        }
    }

    @discardableResult
    func revoke() -> Bool {
        stateLock.withLock {
            guard case .active = state else { return false }
            state = .revoked
            return true
        }
    }

    func commit<Result>(_ operation: () throws -> Result) throws -> Result {
        stateLock.lock()
        guard case .active = state else {
            stateLock.unlock()
            throw DatabaseBrokerExecutableLaunchLeaseError.notPermitted
        }
        guard monotonicNanoseconds() < deadlineNanoseconds else {
            state = .revoked
            stateLock.unlock()
            throw DatabaseBrokerExecutableLaunchLeaseError.notPermitted
        }
        state = .committed
        stateLock.unlock()
        do {
            return try operation()
        } catch {
            stateLock.withLock {
                state = .failed
            }
            throw error
        }
    }

    static func unbounded() -> DatabaseBrokerExecutableLaunchLease {
        DatabaseBrokerExecutableLaunchLease(
            deadlineNanoseconds: UInt64.max,
            monotonicNanoseconds: {
                DispatchTime.now().uptimeNanoseconds
            })
    }
}

struct DatabaseBrokerExecutableFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
}

struct DatabaseBrokerExecutableFileMetadata: Equatable, Sendable {
    let identity: DatabaseBrokerExecutableFileIdentity
    let mode: UInt32
}

struct DatabaseBrokerExecutableCodeValidationOptions: OptionSet, Sendable {
    let rawValue: UInt8

    static let offline = Self(rawValue: 1 << 0)
    static let strict = Self(rawValue: 1 << 1)
    static let allArchitectures = Self(rawValue: 1 << 2)
    static let restrictSymlinks = Self(rawValue: 1 << 3)
}

protocol DatabaseBrokerExecutableFileSystem: Sendable {
    associatedtype Descriptor: Sendable

    func copyExecutablePath(
        into buffer: UnsafeMutablePointer<CChar>, size: inout UInt32
    ) -> Int32
    func canonicalPath(for path: String) throws -> String
    func openExecutable(at path: String, flags: Int32) throws -> Descriptor
    func metadata(for descriptor: Descriptor) throws -> DatabaseBrokerExecutableFileMetadata
    func metadata(at path: String) throws -> DatabaseBrokerExecutableFileMetadata
    func descriptorFlags(for descriptor: Descriptor) throws -> Int32
    func closeExecutable(_ descriptor: Descriptor)
}

protocol DatabaseBrokerExecutableCodeSigningSystem: Sendable {
    associatedtype Code: Sendable
    associatedtype StaticCode: Sendable
    associatedtype Requirement: Sendable

    func currentCode() throws -> Code
    func staticCode(for code: Code) throws -> StaticCode
    func designatedRequirement(for code: StaticCode) throws -> Requirement
    func validateCurrent(
        code: Code,
        requirement: Requirement,
        options: DatabaseBrokerExecutableCodeValidationOptions
    ) throws
    func candidateStaticCode(at path: String) throws -> StaticCode
    func validateCandidate(
        code: StaticCode,
        requirement: Requirement,
        options: DatabaseBrokerExecutableCodeValidationOptions
    ) throws
    func uniqueIdentifier(for code: StaticCode) throws -> Data
}

final class DatabaseBrokerValidatedExecutable: @unchecked Sendable {
    let path: String
    let identity: DatabaseBrokerExecutableFileIdentity
    private let revalidateImplementation: @Sendable () throws -> Void

    fileprivate init(
        path: String,
        identity: DatabaseBrokerExecutableFileIdentity,
        revalidate: @escaping @Sendable () throws -> Void
    ) {
        self.path = path
        self.identity = identity
        revalidateImplementation = revalidate
    }

    func revalidate() throws {
        try revalidateImplementation()
    }
}

struct DatabaseBrokerExecutableResolver: Sendable {
    private let resolveCurrentImplementation:
        @Sendable () throws -> DatabaseBrokerValidatedExecutable

    init() {
        self.init(
            fileSystem: MacOSDatabaseBrokerExecutableFileSystem(),
            codeSigningSystem: MacOSDatabaseBrokerExecutableCodeSigningSystem())
    }

    init<
        FileSystem: DatabaseBrokerExecutableFileSystem,
        CodeSigningSystem: DatabaseBrokerExecutableCodeSigningSystem
    >(
        fileSystem: FileSystem,
        codeSigningSystem: CodeSigningSystem
    ) {
        let algorithm = DatabaseBrokerExecutableResolutionAlgorithm(
            fileSystem: fileSystem,
            codeSigningSystem: codeSigningSystem)
        resolveCurrentImplementation = {
            try algorithm.resolveCurrent()
        }
    }

    func resolveCurrent() throws -> DatabaseBrokerValidatedExecutable {
        try resolveCurrentImplementation()
    }
}

struct DatabaseBrokerExecutableCandidateValidator: Sendable {
    private let validateImplementation: @Sendable (String) throws -> Void

    init() throws {
        let system = MacOSDatabaseBrokerExecutableCodeSigningSystem()
        let currentCode = try system.currentCode()
        let currentStaticCode = try system.staticCode(for: currentCode)
        let requirement = try system.designatedRequirement(for: currentStaticCode)
        let options: DatabaseBrokerExecutableCodeValidationOptions = [
            .offline,
            .strict,
            .allArchitectures,
            .restrictSymlinks,
        ]
        try system.validateCurrent(
            code: currentCode,
            requirement: requirement,
            options: options)
        validateImplementation = { path in
            let candidate = try system.candidateStaticCode(at: path)
            try system.validateCandidate(
                code: candidate,
                requirement: requirement,
                options: options)
        }
    }

    func validate(path: String) throws {
        try validateImplementation(path)
    }
}

struct DatabaseBrokerSpawnRequest: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let flags: Int16
    let defaultSignals: Set<Int32>
    let signalMask: Set<Int32>
    let standardInputPath: String
    let standardOutputPath: String
    let standardErrorPath: String
}

protocol DatabaseBrokerProcessSpawningSystem: Sendable {
    func spawn(_ request: DatabaseBrokerSpawnRequest) throws -> pid_t
    func registerReaper(for processIdentifier: pid_t)
}

struct DatabaseBrokerProcessSpawner: Sendable {
    private let spawnImplementation:
        @Sendable (
            DatabaseBrokerValidatedExecutable,
            DatabaseBrokerExecutableLaunchLease
        ) throws -> pid_t

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(
            system: MacOSDatabaseBrokerProcessSpawningSystem(),
            environment: environment)
    }

    init<System: DatabaseBrokerProcessSpawningSystem>(
        system: System,
        environment: [String: String]
    ) {
        spawnImplementation = { executable, lease in
            try executable.revalidate()
            let request = DatabaseBrokerSpawnRequest(
                executablePath: executable.path,
                arguments: [executable.path],
                environment: Self.sanitizedEnvironment(environment),
                flags: Int16(
                    POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID
                        | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK),
                defaultSignals: Self.catchableSignals,
                signalMask: [],
                standardInputPath: "/dev/null",
                standardOutputPath: "/dev/null",
                standardErrorPath: "/dev/null")
            return try lease.commit {
                let processIdentifier: pid_t
                do {
                    processIdentifier = try system.spawn(request)
                } catch let error as DatabaseBrokerExecutableLauncherError {
                    throw error
                } catch {
                    throw DatabaseBrokerExecutableLauncherError.spawnFailed
                }
                system.registerReaper(for: processIdentifier)
                return processIdentifier
            }
        }
    }

    @discardableResult
    func spawn(
        _ executable: DatabaseBrokerValidatedExecutable,
        lease: DatabaseBrokerExecutableLaunchLease = .unbounded()
    ) throws -> pid_t {
        try spawnImplementation(executable, lease)
    }

    private static func sanitizedEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        let allowedNames: Set<String> = [
            "HOME",
            "TMPDIR",
            "USER",
            "LOGNAME",
            "LANG",
            "LC_ALL",
            "LC_COLLATE",
            "LC_CTYPE",
            "LC_MESSAGES",
            "LC_MONETARY",
            "LC_NUMERIC",
            "LC_TIME",
        ]
        var sanitized: [String: String] = [:]
        for (name, value) in environment {
            guard allowedNames.contains(name), !value.utf8.contains(0) else {
                continue
            }
            sanitized[name] = value
        }
        sanitized["EDITH_DATABASE_BROKER"] = "1"
        return sanitized
    }

    private static let catchableSignals = Set(
        (Int32(1)..<Int32(NSIG)).filter { signal in
            signal != SIGKILL && signal != SIGSTOP
        })
}

struct DatabaseBrokerExecutableLauncher: Sendable {
    private let executable: DatabaseBrokerValidatedExecutable
    private let spawner: DatabaseBrokerProcessSpawner

    init() throws {
        executable = try DatabaseBrokerExecutableResolver().resolveCurrent()
        spawner = DatabaseBrokerProcessSpawner()
    }

    init(
        resolver: DatabaseBrokerExecutableResolver,
        spawner: DatabaseBrokerProcessSpawner
    ) throws {
        executable = try resolver.resolveCurrent()
        self.spawner = spawner
    }

    func launch() throws {
        try spawner.spawn(executable)
    }

    func launch(lease: DatabaseBrokerExecutableLaunchLease) throws {
        try spawner.spawn(executable, lease: lease)
    }
}

private struct DatabaseBrokerCurrentExecutableCodeIdentity<Requirement: Sendable>:
    Sendable
{
    let designatedRequirement: Requirement
    let uniqueIdentifier: Data
}

private final class DatabaseBrokerExecutableDescriptorLease<
    FileSystem: DatabaseBrokerExecutableFileSystem
>: @unchecked Sendable {
    let fileSystem: FileSystem
    let descriptor: FileSystem.Descriptor

    init(fileSystem: FileSystem, descriptor: FileSystem.Descriptor) {
        self.fileSystem = fileSystem
        self.descriptor = descriptor
    }

    deinit {
        fileSystem.closeExecutable(descriptor)
    }
}

private struct DatabaseBrokerExecutableResolutionAlgorithm<
    FileSystem: DatabaseBrokerExecutableFileSystem,
    CodeSigningSystem: DatabaseBrokerExecutableCodeSigningSystem
>: Sendable {
    let fileSystem: FileSystem
    let codeSigningSystem: CodeSigningSystem

    func resolveCurrent() throws -> DatabaseBrokerValidatedExecutable {
        let unresolvedPath = try currentExecutablePath()
        guard unresolvedPath.first == "/", !unresolvedPath.utf8.contains(0) else {
            throw DatabaseBrokerExecutableLauncherError.executablePathInvalid
        }

        let canonicalPath: String
        do {
            canonicalPath = try fileSystem.canonicalPath(for: unresolvedPath)
        } catch {
            throw DatabaseBrokerExecutableLauncherError.executableCanonicalizationFailed
        }
        guard canonicalPath.first == "/", !canonicalPath.utf8.contains(0) else {
            throw DatabaseBrokerExecutableLauncherError.executablePathInvalid
        }

        let descriptor: FileSystem.Descriptor
        do {
            descriptor = try fileSystem.openExecutable(
                at: canonicalPath,
                flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        } catch {
            throw DatabaseBrokerExecutableLauncherError.executableOpenFailed
        }
        let lease = DatabaseBrokerExecutableDescriptorLease(
            fileSystem: fileSystem,
            descriptor: descriptor)

        let capturedMetadata = try verifiedMetadata(
            path: canonicalPath,
            lease: lease,
            expectedIdentity: nil)
        let currentIdentity = try currentCodeIdentity()
        try validateCandidate(at: canonicalPath, currentIdentity: currentIdentity)
        try verify(
            path: canonicalPath,
            lease: lease,
            expectedIdentity: capturedMetadata.identity)

        return DatabaseBrokerValidatedExecutable(
            path: canonicalPath,
            identity: capturedMetadata.identity,
            revalidate: {
                try verify(
                    path: canonicalPath,
                    lease: lease,
                    expectedIdentity: capturedMetadata.identity)
            })
    }

    private func currentExecutablePath() throws -> String {
        var capacity = UInt32(256)
        while true {
            guard capacity > 1, let count = Int(exactly: capacity) else {
                throw DatabaseBrokerExecutableLauncherError.executablePathUnavailable
            }
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: count)
            buffer.initialize(repeating: 0, count: count)
            defer { buffer.deallocate() }
            var requestedSize = capacity
            let result = fileSystem.copyExecutablePath(
                into: buffer,
                size: &requestedSize)
            if result == 0 {
                guard
                    let terminator = UnsafeBufferPointer(start: buffer, count: count)
                        .firstIndex(of: 0),
                    terminator > 0
                else {
                    throw DatabaseBrokerExecutableLauncherError.executablePathInvalid
                }
                guard let path = String(validatingCString: buffer) else {
                    throw DatabaseBrokerExecutableLauncherError.executablePathInvalid
                }
                return path
            }
            guard result == -1, requestedSize > capacity else {
                throw DatabaseBrokerExecutableLauncherError.executablePathUnavailable
            }
            capacity = requestedSize
        }
    }

    private func currentCodeIdentity() throws
        -> DatabaseBrokerCurrentExecutableCodeIdentity<CodeSigningSystem.Requirement>
    {
        let currentCode: CodeSigningSystem.Code
        do {
            currentCode = try codeSigningSystem.currentCode()
        } catch {
            throw DatabaseBrokerExecutableLauncherError.currentCodeUnavailable
        }

        let currentStaticCode: CodeSigningSystem.StaticCode
        do {
            currentStaticCode = try codeSigningSystem.staticCode(for: currentCode)
        } catch {
            throw DatabaseBrokerExecutableLauncherError.currentStaticCodeUnavailable
        }

        let designatedRequirement: CodeSigningSystem.Requirement
        do {
            designatedRequirement = try codeSigningSystem.designatedRequirement(
                for: currentStaticCode)
        } catch {
            throw DatabaseBrokerExecutableLauncherError.currentDesignatedRequirementUnavailable
        }

        do {
            try codeSigningSystem.validateCurrent(
                code: currentCode,
                requirement: designatedRequirement,
                options: [.offline])
        } catch {
            throw DatabaseBrokerExecutableLauncherError.currentCodeInvalid
        }

        let uniqueIdentifier: Data
        do {
            uniqueIdentifier = try codeSigningSystem.uniqueIdentifier(for: currentStaticCode)
        } catch {
            throw DatabaseBrokerExecutableLauncherError.currentUniqueIdentifierUnavailable
        }
        guard !uniqueIdentifier.isEmpty else {
            throw DatabaseBrokerExecutableLauncherError.currentUniqueIdentifierUnavailable
        }

        return DatabaseBrokerCurrentExecutableCodeIdentity(
            designatedRequirement: designatedRequirement,
            uniqueIdentifier: uniqueIdentifier)
    }

    private func validateCandidate(
        at path: String,
        currentIdentity: DatabaseBrokerCurrentExecutableCodeIdentity<
            CodeSigningSystem.Requirement
        >
    ) throws {
        let candidateCode: CodeSigningSystem.StaticCode
        do {
            candidateCode = try codeSigningSystem.candidateStaticCode(at: path)
        } catch {
            throw DatabaseBrokerExecutableLauncherError.candidateStaticCodeUnavailable
        }

        do {
            try codeSigningSystem.validateCandidate(
                code: candidateCode,
                requirement: currentIdentity.designatedRequirement,
                options: [.offline, .strict, .allArchitectures, .restrictSymlinks])
        } catch {
            throw DatabaseBrokerExecutableLauncherError.candidateCodeInvalid
        }

        let candidateUniqueIdentifier: Data
        do {
            candidateUniqueIdentifier = try codeSigningSystem.uniqueIdentifier(
                for: candidateCode)
        } catch {
            throw DatabaseBrokerExecutableLauncherError.candidateUniqueIdentifierUnavailable
        }
        guard !candidateUniqueIdentifier.isEmpty else {
            throw DatabaseBrokerExecutableLauncherError.candidateUniqueIdentifierUnavailable
        }
        guard candidateUniqueIdentifier == currentIdentity.uniqueIdentifier else {
            throw DatabaseBrokerExecutableLauncherError.candidateUniqueIdentifierMismatch
        }
    }

    private func verify(
        path: String,
        lease: DatabaseBrokerExecutableDescriptorLease<FileSystem>,
        expectedIdentity: DatabaseBrokerExecutableFileIdentity
    ) throws {
        _ = try verifiedMetadata(
            path: path,
            lease: lease,
            expectedIdentity: expectedIdentity)
    }

    private func verifiedMetadata(
        path: String,
        lease: DatabaseBrokerExecutableDescriptorLease<FileSystem>,
        expectedIdentity: DatabaseBrokerExecutableFileIdentity?
    ) throws -> DatabaseBrokerExecutableFileMetadata {
        let descriptorMetadata: DatabaseBrokerExecutableFileMetadata
        let pathMetadata: DatabaseBrokerExecutableFileMetadata
        let descriptorFlags: Int32
        do {
            descriptorMetadata = try fileSystem.metadata(for: lease.descriptor)
            pathMetadata = try fileSystem.metadata(at: path)
            descriptorFlags = try fileSystem.descriptorFlags(for: lease.descriptor)
        } catch {
            throw DatabaseBrokerExecutableLauncherError.executableMetadataUnavailable
        }

        guard
            Self.isRegularExecutable(descriptorMetadata),
            Self.isRegularExecutable(pathMetadata),
            descriptorFlags & FD_CLOEXEC == FD_CLOEXEC
        else {
            throw DatabaseBrokerExecutableLauncherError.executableUnsafe
        }
        guard descriptorMetadata.identity == pathMetadata.identity else {
            throw DatabaseBrokerExecutableLauncherError.executableReplaced
        }
        if let expectedIdentity {
            guard descriptorMetadata.identity == expectedIdentity else {
                throw DatabaseBrokerExecutableLauncherError.executableReplaced
            }
        }
        return descriptorMetadata
    }

    private static func isRegularExecutable(
        _ metadata: DatabaseBrokerExecutableFileMetadata
    ) -> Bool {
        metadata.mode & UInt32(S_IFMT) == UInt32(S_IFREG)
            && metadata.mode & UInt32(S_IXUSR | S_IXGRP | S_IXOTH) != 0
            && metadata.identity.size > 0
    }
}

private enum MacOSDatabaseBrokerExecutableSystemError: Error, Sendable {
    case systemCallFailed
}

private struct MacOSDatabaseBrokerExecutableFileSystem:
    DatabaseBrokerExecutableFileSystem
{
    func copyExecutablePath(
        into buffer: UnsafeMutablePointer<CChar>, size: inout UInt32
    ) -> Int32 {
        _NSGetExecutablePath(buffer, &size)
    }

    func canonicalPath(for path: String) throws -> String {
        guard
            let canonicalPath = path.withCString({ unresolvedPath in
                realpath(unresolvedPath, nil)
            })
        else {
            throw MacOSDatabaseBrokerExecutableSystemError.systemCallFailed
        }
        defer { free(canonicalPath) }
        return String(cString: canonicalPath)
    }

    func openExecutable(at path: String, flags: Int32) throws -> Int32 {
        let descriptor = Darwin.open(path, flags)
        guard descriptor >= 0 else {
            throw MacOSDatabaseBrokerExecutableSystemError.systemCallFailed
        }
        return descriptor
    }

    func metadata(for descriptor: Int32) throws -> DatabaseBrokerExecutableFileMetadata {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw MacOSDatabaseBrokerExecutableSystemError.systemCallFailed
        }
        return metadata(from: value)
    }

    func metadata(at path: String) throws -> DatabaseBrokerExecutableFileMetadata {
        var value = stat()
        guard lstat(path, &value) == 0 else {
            throw MacOSDatabaseBrokerExecutableSystemError.systemCallFailed
        }
        return metadata(from: value)
    }

    func descriptorFlags(for descriptor: Int32) throws -> Int32 {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0 else {
            throw MacOSDatabaseBrokerExecutableSystemError.systemCallFailed
        }
        return flags
    }

    func closeExecutable(_ descriptor: Int32) {
        _ = Darwin.close(descriptor)
    }

    private func metadata(from value: stat) -> DatabaseBrokerExecutableFileMetadata {
        DatabaseBrokerExecutableFileMetadata(
            identity: DatabaseBrokerExecutableFileIdentity(
                device: UInt64(value.st_dev),
                inode: UInt64(value.st_ino),
                size: Int64(value.st_size),
                modificationSeconds: Int64(value.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec)),
            mode: UInt32(value.st_mode))
    }
}

private struct MacOSDatabaseBrokerExecutableCode: @unchecked Sendable {
    let value: SecCode
}

private struct MacOSDatabaseBrokerExecutableStaticCode: @unchecked Sendable {
    let value: SecStaticCode
}

private struct MacOSDatabaseBrokerExecutableRequirement: @unchecked Sendable {
    let value: SecRequirement
}

private struct MacOSDatabaseBrokerExecutableCodeSigningSystem:
    DatabaseBrokerExecutableCodeSigningSystem
{
    private static let defaultFlags = SecCSFlags()
    private static let signingInformationFlags = SecCSFlags(
        rawValue: kSecCSSigningInformation)

    func currentCode() throws -> MacOSDatabaseBrokerExecutableCode {
        var code: SecCode?
        guard
            SecCodeCopySelf(Self.defaultFlags, &code) == errSecSuccess,
            let code
        else {
            throw MacOSDatabaseBrokerExecutableSystemError.systemCallFailed
        }
        return MacOSDatabaseBrokerExecutableCode(value: code)
    }

    func staticCode(
        for code: MacOSDatabaseBrokerExecutableCode
    ) throws -> MacOSDatabaseBrokerExecutableStaticCode {
        var staticCode: SecStaticCode?
        guard
            SecCodeCopyStaticCode(
                code.value,
                Self.defaultFlags,
                &staticCode) == errSecSuccess,
            let staticCode
        else {
            throw MacOSDatabaseBrokerExecutableSystemError.systemCallFailed
        }
        return MacOSDatabaseBrokerExecutableStaticCode(value: staticCode)
    }

    func designatedRequirement(
        for code: MacOSDatabaseBrokerExecutableStaticCode
    ) throws -> MacOSDatabaseBrokerExecutableRequirement {
        var requirement: SecRequirement?
        guard
            SecCodeCopyDesignatedRequirement(
                code.value,
                Self.defaultFlags,
                &requirement) == errSecSuccess,
            let requirement
        else {
            throw MacOSDatabaseBrokerExecutableSystemError.systemCallFailed
        }
        return MacOSDatabaseBrokerExecutableRequirement(value: requirement)
    }

    func validateCurrent(
        code: MacOSDatabaseBrokerExecutableCode,
        requirement: MacOSDatabaseBrokerExecutableRequirement,
        options: DatabaseBrokerExecutableCodeValidationOptions
    ) throws {
        guard
            SecCodeCheckValidity(
                code.value,
                validationFlags(for: options),
                requirement.value) == errSecSuccess
        else {
            throw MacOSDatabaseBrokerExecutableSystemError.systemCallFailed
        }
    }

    func candidateStaticCode(
        at path: String
    ) throws -> MacOSDatabaseBrokerExecutableStaticCode {
        var code: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(
                URL(fileURLWithPath: path) as CFURL,
                Self.defaultFlags,
                &code) == errSecSuccess,
            let code
        else {
            throw MacOSDatabaseBrokerExecutableSystemError.systemCallFailed
        }
        return MacOSDatabaseBrokerExecutableStaticCode(value: code)
    }

    func validateCandidate(
        code: MacOSDatabaseBrokerExecutableStaticCode,
        requirement: MacOSDatabaseBrokerExecutableRequirement,
        options: DatabaseBrokerExecutableCodeValidationOptions
    ) throws {
        guard
            SecStaticCodeCheckValidity(
                code.value,
                validationFlags(for: options),
                requirement.value) == errSecSuccess
        else {
            throw MacOSDatabaseBrokerExecutableSystemError.systemCallFailed
        }
    }

    func uniqueIdentifier(for code: MacOSDatabaseBrokerExecutableStaticCode) throws -> Data {
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code.value,
                Self.signingInformationFlags,
                &information) == errSecSuccess,
            let signingInformation = information as? [String: Any],
            let uniqueIdentifier = signingInformation[kSecCodeInfoUnique as String] as? Data,
            !uniqueIdentifier.isEmpty
        else {
            throw MacOSDatabaseBrokerExecutableSystemError.systemCallFailed
        }
        return uniqueIdentifier
    }

    private func validationFlags(
        for options: DatabaseBrokerExecutableCodeValidationOptions
    ) -> SecCSFlags {
        var flags = SecCSFlags()
        if options.contains(.offline) {
            flags.formUnion(.noNetworkAccess)
        }
        if options.contains(.strict) {
            flags.formUnion(SecCSFlags(rawValue: kSecCSStrictValidate))
        }
        if options.contains(.allArchitectures) {
            flags.formUnion(SecCSFlags(rawValue: kSecCSCheckAllArchitectures))
        }
        if options.contains(.restrictSymlinks) {
            flags.formUnion(SecCSFlags(rawValue: kSecCSRestrictSymlinks))
        }
        return flags
    }
}

private struct MacOSDatabaseBrokerProcessSpawningSystem:
    DatabaseBrokerProcessSpawningSystem
{
    func spawn(_ request: DatabaseBrokerSpawnRequest) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw DatabaseBrokerExecutableLauncherError.spawnConfigurationFailed
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw DatabaseBrokerExecutableLauncherError.spawnConfigurationFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }

        try addOpenAction(
            &fileActions,
            descriptor: STDIN_FILENO,
            path: request.standardInputPath,
            flags: O_RDONLY)
        try addOpenAction(
            &fileActions,
            descriptor: STDOUT_FILENO,
            path: request.standardOutputPath,
            flags: O_WRONLY)
        try addOpenAction(
            &fileActions,
            descriptor: STDERR_FILENO,
            path: request.standardErrorPath,
            flags: O_WRONLY)

        guard posix_spawnattr_setflags(&attributes, request.flags) == 0 else {
            throw DatabaseBrokerExecutableLauncherError.spawnConfigurationFailed
        }

        var defaultSignals = sigset_t()
        guard sigemptyset(&defaultSignals) == 0 else {
            throw DatabaseBrokerExecutableLauncherError.spawnConfigurationFailed
        }
        for signal in request.defaultSignals {
            guard sigaddset(&defaultSignals, signal) == 0 else {
                throw DatabaseBrokerExecutableLauncherError.spawnConfigurationFailed
            }
        }
        guard posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0 else {
            throw DatabaseBrokerExecutableLauncherError.spawnConfigurationFailed
        }

        var signalMask = sigset_t()
        guard sigemptyset(&signalMask) == 0, request.signalMask.isEmpty else {
            throw DatabaseBrokerExecutableLauncherError.spawnConfigurationFailed
        }
        guard posix_spawnattr_setsigmask(&attributes, &signalMask) == 0 else {
            throw DatabaseBrokerExecutableLauncherError.spawnConfigurationFailed
        }

        let argumentStorage = try allocateStrings(request.arguments)
        defer { releaseStrings(argumentStorage) }
        var argumentPointers = argumentStorage + [nil]
        let environmentStorage = try allocateStrings(
            request.environment.keys.sorted().compactMap { name in
                request.environment[name].map { "\(name)=\($0)" }
            })
        defer { releaseStrings(environmentStorage) }
        var environmentPointers = environmentStorage + [nil]
        var processIdentifier = pid_t()
        let result = request.executablePath.withCString { executablePath in
            argumentPointers.withUnsafeMutableBufferPointer { arguments in
                environmentPointers.withUnsafeMutableBufferPointer { environment in
                    posix_spawn(
                        &processIdentifier,
                        executablePath,
                        &fileActions,
                        &attributes,
                        arguments.baseAddress,
                        environment.baseAddress)
                }
            }
        }
        guard result == 0 else {
            throw DatabaseBrokerExecutableLauncherError.spawnFailed
        }
        return processIdentifier
    }

    func registerReaper(for processIdentifier: pid_t) {
        DatabaseBrokerChildProcessReaper.shared.register(processIdentifier)
    }

    private func addOpenAction(
        _ fileActions: inout posix_spawn_file_actions_t?,
        descriptor: Int32,
        path: String,
        flags: Int32
    ) throws {
        let result = path.withCString { pathPointer in
            posix_spawn_file_actions_addopen(
                &fileActions,
                descriptor,
                pathPointer,
                flags,
                0)
        }
        guard result == 0 else {
            throw DatabaseBrokerExecutableLauncherError.spawnConfigurationFailed
        }
    }

    private func allocateStrings(_ values: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        let storage = values.map { strdup($0) }
        guard storage.allSatisfy({ $0 != nil }) else {
            releaseStrings(storage)
            throw DatabaseBrokerExecutableLauncherError.spawnConfigurationFailed
        }
        return storage
    }

    private func releaseStrings(_ storage: [UnsafeMutablePointer<CChar>?]) {
        storage.compactMap { $0 }.forEach { free($0) }
    }
}

private final class DatabaseBrokerChildProcessReaper: @unchecked Sendable {
    static let shared = DatabaseBrokerChildProcessReaper()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.edith.database.broker-child-reaper")
    private var sources: [pid_t: DispatchSourceProcess] = [:]

    func register(_ processIdentifier: pid_t) {
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: queue)
        source.setEventHandler { [weak self] in
            self?.reap(processIdentifier)
        }
        lock.lock()
        sources[processIdentifier] = source
        lock.unlock()
        source.resume()
    }

    private func reap(_ processIdentifier: pid_t) {
        while true {
            var status = Int32()
            let result = waitpid(processIdentifier, &status, 0)
            if result == processIdentifier || result == -1 && errno != EINTR {
                break
            }
        }
        lock.lock()
        let source = sources.removeValue(forKey: processIdentifier)
        lock.unlock()
        source?.cancel()
    }
}
