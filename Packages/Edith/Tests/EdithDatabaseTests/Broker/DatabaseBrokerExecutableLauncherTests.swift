import Darwin
import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseBrokerExecutableLauncherSystemStubError: Error {
    case requestedFailure
}

private final class DatabaseBrokerExecutableFileSystemStub: @unchecked Sendable,
    DatabaseBrokerExecutableFileSystem
{
    enum Failure: Equatable {
        case copyPath
        case canonicalPath
        case open
        case descriptorMetadata
        case pathMetadata
        case descriptorFlags
    }

    enum Call: Equatable {
        case copyPath(Int)
        case canonicalPath(String)
        case open(String, Int32)
        case descriptorMetadata(Int32)
        case pathMetadata(String)
        case descriptorFlags(Int32)
        case close(Int32)
    }

    var unresolvedPath = "/Applications/Edith.app/Contents/MacOS/edith"
    var canonicalPath = "/Applications/Edith.app/Contents/MacOS/edith"
    var descriptor = Int32(73)
    var descriptorMetadataValues = [DatabaseBrokerExecutableLauncherTestValues.metadata]
    var pathMetadataValues = [DatabaseBrokerExecutableLauncherTestValues.metadata]
    var descriptorFlagValues = [FD_CLOEXEC]
    var failure: Failure?
    var calls: [Call] = []

    func copyExecutablePath(
        into buffer: UnsafeMutablePointer<CChar>, size: inout UInt32
    ) -> Int32 {
        calls.append(.copyPath(Int(size)))
        if failure == .copyPath {
            return 1
        }
        let bytes = Array(unresolvedPath.utf8) + [0]
        if Int(size) < bytes.count {
            size = UInt32(bytes.count)
            return -1
        }
        for (index, byte) in bytes.enumerated() {
            buffer[index] = CChar(bitPattern: byte)
        }
        return 0
    }

    func canonicalPath(for path: String) throws -> String {
        calls.append(.canonicalPath(path))
        try failIfRequested(.canonicalPath)
        return canonicalPath
    }

    func openExecutable(at path: String, flags: Int32) throws -> Int32 {
        calls.append(.open(path, flags))
        try failIfRequested(.open)
        return descriptor
    }

    func metadata(for descriptor: Int32) throws -> DatabaseBrokerExecutableFileMetadata {
        calls.append(.descriptorMetadata(descriptor))
        try failIfRequested(.descriptorMetadata)
        return nextValue(&descriptorMetadataValues)
    }

    func metadata(at path: String) throws -> DatabaseBrokerExecutableFileMetadata {
        calls.append(.pathMetadata(path))
        try failIfRequested(.pathMetadata)
        return nextValue(&pathMetadataValues)
    }

    func descriptorFlags(for descriptor: Int32) throws -> Int32 {
        calls.append(.descriptorFlags(descriptor))
        try failIfRequested(.descriptorFlags)
        return nextValue(&descriptorFlagValues)
    }

    func closeExecutable(_ descriptor: Int32) {
        calls.append(.close(descriptor))
    }

    private func nextValue<Value>(_ values: inout [Value]) -> Value {
        if values.count > 1 {
            return values.removeFirst()
        }
        return values[0]
    }

    private func failIfRequested(_ requestedFailure: Failure) throws {
        if failure == requestedFailure {
            throw DatabaseBrokerExecutableLauncherSystemStubError.requestedFailure
        }
    }
}

private final class DatabaseBrokerExecutableCodeSigningSystemStub: @unchecked Sendable,
    DatabaseBrokerExecutableCodeSigningSystem
{
    enum Code: Equatable, Sendable {
        case current
    }

    enum StaticCode: Equatable, Hashable, Sendable {
        case current
        case candidate
    }

    enum Requirement: Equatable, Sendable {
        case current
    }

    enum Failure: Equatable {
        case currentCode
        case currentStaticCode
        case designatedRequirement
        case currentValidation
        case currentUniqueIdentifier
        case candidateStaticCode
        case candidateValidation
        case candidateUniqueIdentifier
    }

    enum Call: Equatable {
        case currentCode
        case staticCode(Code)
        case designatedRequirement(StaticCode)
        case validateCurrent(
            Code,
            Requirement,
            DatabaseBrokerExecutableCodeValidationOptions
        )
        case candidateStaticCode(String)
        case validateCandidate(
            StaticCode,
            Requirement,
            DatabaseBrokerExecutableCodeValidationOptions
        )
        case uniqueIdentifier(StaticCode)
    }

    var uniqueIdentifiers: [StaticCode: Data] = [
        .current: Data([0x10, 0x20, 0x30]),
        .candidate: Data([0x10, 0x20, 0x30]),
    ]
    var failure: Failure?
    var candidateValidationAction: (() -> Void)?
    var calls: [Call] = []

    func currentCode() throws -> Code {
        calls.append(.currentCode)
        try failIfRequested(.currentCode)
        return .current
    }

    func staticCode(for code: Code) throws -> StaticCode {
        calls.append(.staticCode(code))
        try failIfRequested(.currentStaticCode)
        return .current
    }

    func designatedRequirement(for code: StaticCode) throws -> Requirement {
        calls.append(.designatedRequirement(code))
        try failIfRequested(.designatedRequirement)
        return .current
    }

    func validateCurrent(
        code: Code,
        requirement: Requirement,
        options: DatabaseBrokerExecutableCodeValidationOptions
    ) throws {
        calls.append(.validateCurrent(code, requirement, options))
        try failIfRequested(.currentValidation)
    }

    func candidateStaticCode(at path: String) throws -> StaticCode {
        calls.append(.candidateStaticCode(path))
        try failIfRequested(.candidateStaticCode)
        return .candidate
    }

    func validateCandidate(
        code: StaticCode,
        requirement: Requirement,
        options: DatabaseBrokerExecutableCodeValidationOptions
    ) throws {
        calls.append(.validateCandidate(code, requirement, options))
        candidateValidationAction?()
        try failIfRequested(.candidateValidation)
    }

    func uniqueIdentifier(for code: StaticCode) throws -> Data {
        calls.append(.uniqueIdentifier(code))
        switch code {
        case .current:
            try failIfRequested(.currentUniqueIdentifier)
        case .candidate:
            try failIfRequested(.candidateUniqueIdentifier)
        }
        guard let uniqueIdentifier = uniqueIdentifiers[code] else {
            throw DatabaseBrokerExecutableLauncherSystemStubError.requestedFailure
        }
        return uniqueIdentifier
    }

    private func failIfRequested(_ requestedFailure: Failure) throws {
        if failure == requestedFailure {
            throw DatabaseBrokerExecutableLauncherSystemStubError.requestedFailure
        }
    }
}

private final class DatabaseBrokerProcessSpawningSystemStub: @unchecked Sendable,
    DatabaseBrokerProcessSpawningSystem
{
    var processIdentifier = pid_t(9127)
    var failsSpawn = false
    var requests: [DatabaseBrokerSpawnRequest] = []
    var reapedProcessIdentifiers: [pid_t] = []

    func spawn(_ request: DatabaseBrokerSpawnRequest) throws -> pid_t {
        requests.append(request)
        if failsSpawn {
            throw DatabaseBrokerExecutableLauncherSystemStubError.requestedFailure
        }
        return processIdentifier
    }

    func registerReaper(for processIdentifier: pid_t) {
        reapedProcessIdentifiers.append(processIdentifier)
    }
}

private enum DatabaseBrokerExecutableLauncherTestValues {
    static let identity = DatabaseBrokerExecutableFileIdentity(
        device: 8,
        inode: 13,
        size: 4_096,
        modificationSeconds: 1_800_000_000,
        modificationNanoseconds: 123_456_789)
    static let replacementIdentity = DatabaseBrokerExecutableFileIdentity(
        device: 8,
        inode: 21,
        size: 4_096,
        modificationSeconds: 1_800_000_000,
        modificationNanoseconds: 123_456_789)
    static let metadata = DatabaseBrokerExecutableFileMetadata(
        identity: identity,
        mode: UInt32(S_IFREG | S_IRUSR | S_IXUSR))
    static let replacementMetadata = DatabaseBrokerExecutableFileMetadata(
        identity: replacementIdentity,
        mode: UInt32(S_IFREG | S_IRUSR | S_IXUSR))
}

@Suite struct DatabaseBrokerExecutableResolverTests {
    @Test func resolvesDynamicCanonicalPathAndValidatesExactCurrentIdentity() throws {
        let fileSystem = DatabaseBrokerExecutableFileSystemStub()
        fileSystem.unresolvedPath = "/" + String(repeating: "a", count: 300)
        fileSystem.canonicalPath = "/Applications/Edith.app/Contents/MacOS/edith"
        let codeSigningSystem = DatabaseBrokerExecutableCodeSigningSystemStub()

        let executable = try DatabaseBrokerExecutableResolver(
            fileSystem: fileSystem,
            codeSigningSystem: codeSigningSystem
        ).resolveCurrent()

        #expect(executable.path == fileSystem.canonicalPath)
        #expect(executable.identity == DatabaseBrokerExecutableLauncherTestValues.identity)
        #expect(
            fileSystem.calls == [
                .copyPath(256),
                .copyPath(302),
                .canonicalPath(fileSystem.unresolvedPath),
                .open(fileSystem.canonicalPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW),
                .descriptorMetadata(fileSystem.descriptor),
                .pathMetadata(fileSystem.canonicalPath),
                .descriptorFlags(fileSystem.descriptor),
                .descriptorMetadata(fileSystem.descriptor),
                .pathMetadata(fileSystem.canonicalPath),
                .descriptorFlags(fileSystem.descriptor),
            ])
        #expect(
            codeSigningSystem.calls == [
                .currentCode,
                .staticCode(.current),
                .designatedRequirement(.current),
                .validateCurrent(.current, .current, [.offline]),
                .uniqueIdentifier(.current),
                .candidateStaticCode(fileSystem.canonicalPath),
                .validateCandidate(
                    .candidate,
                    .current,
                    [.offline, .strict, .allArchitectures, .restrictSymlinks]),
                .uniqueIdentifier(.candidate),
            ])
    }

    @Test func retainsDescriptorUntilValidatedExecutableIsReleased() throws {
        let fileSystem = DatabaseBrokerExecutableFileSystemStub()
        let codeSigningSystem = DatabaseBrokerExecutableCodeSigningSystemStub()
        var executable: DatabaseBrokerValidatedExecutable? = try DatabaseBrokerExecutableResolver(
            fileSystem: fileSystem,
            codeSigningSystem: codeSigningSystem
        ).resolveCurrent()

        #expect(!fileSystem.calls.contains(.close(fileSystem.descriptor)))
        executable = nil

        #expect(executable == nil)
        #expect(fileSystem.calls.last == .close(fileSystem.descriptor))
    }

    @Test(
        arguments: [
            DatabaseBrokerExecutableFileSystemStub.Failure.copyPath,
            .canonicalPath,
            .open,
            .descriptorMetadata,
            .pathMetadata,
            .descriptorFlags,
        ])
    fileprivate func mapsFileSystemFailures(
        failure: DatabaseBrokerExecutableFileSystemStub.Failure
    ) {
        let fileSystem = DatabaseBrokerExecutableFileSystemStub()
        let codeSigningSystem = DatabaseBrokerExecutableCodeSigningSystemStub()
        fileSystem.failure = failure
        let expectedError: DatabaseBrokerExecutableLauncherError
        switch failure {
        case .copyPath:
            expectedError = .executablePathUnavailable
        case .canonicalPath:
            expectedError = .executableCanonicalizationFailed
        case .open:
            expectedError = .executableOpenFailed
        case .descriptorMetadata, .pathMetadata, .descriptorFlags:
            expectedError = .executableMetadataUnavailable
        }

        #expect(throws: expectedError) {
            try DatabaseBrokerExecutableResolver(
                fileSystem: fileSystem,
                codeSigningSystem: codeSigningSystem
            ).resolveCurrent()
        }
    }

    @Test func rejectsRelativeAndMalformedExecutablePaths() {
        let relativeFileSystem = DatabaseBrokerExecutableFileSystemStub()
        relativeFileSystem.unresolvedPath = "edith"
        let codeSigningSystem = DatabaseBrokerExecutableCodeSigningSystemStub()

        #expect(throws: DatabaseBrokerExecutableLauncherError.executablePathInvalid) {
            try DatabaseBrokerExecutableResolver(
                fileSystem: relativeFileSystem,
                codeSigningSystem: codeSigningSystem
            ).resolveCurrent()
        }

        let relativeCanonicalFileSystem = DatabaseBrokerExecutableFileSystemStub()
        relativeCanonicalFileSystem.canonicalPath = "Applications/Edith"
        #expect(throws: DatabaseBrokerExecutableLauncherError.executablePathInvalid) {
            try DatabaseBrokerExecutableResolver(
                fileSystem: relativeCanonicalFileSystem,
                codeSigningSystem: codeSigningSystem
            ).resolveCurrent()
        }
    }

    @Test(
        arguments: [
            DatabaseBrokerExecutableFileMetadata(
                identity: DatabaseBrokerExecutableLauncherTestValues.identity,
                mode: UInt32(S_IFDIR | S_IRUSR | S_IXUSR)),
            DatabaseBrokerExecutableFileMetadata(
                identity: DatabaseBrokerExecutableLauncherTestValues.identity,
                mode: UInt32(S_IFREG | S_IRUSR)),
            DatabaseBrokerExecutableFileMetadata(
                identity: DatabaseBrokerExecutableFileIdentity(
                    device: 8,
                    inode: 13,
                    size: 0,
                    modificationSeconds: 1_800_000_000,
                    modificationNanoseconds: 123_456_789),
                mode: UInt32(S_IFREG | S_IRUSR | S_IXUSR)),
        ])
    func rejectsUnsafeExecutableMetadata(
        metadata: DatabaseBrokerExecutableFileMetadata
    ) {
        let fileSystem = DatabaseBrokerExecutableFileSystemStub()
        fileSystem.descriptorMetadataValues = [metadata]
        fileSystem.pathMetadataValues = [metadata]

        #expect(throws: DatabaseBrokerExecutableLauncherError.executableUnsafe) {
            try DatabaseBrokerExecutableResolver(
                fileSystem: fileSystem,
                codeSigningSystem: DatabaseBrokerExecutableCodeSigningSystemStub()
            ).resolveCurrent()
        }
    }

    @Test func rejectsDescriptorWithoutCloseOnExec() {
        let fileSystem = DatabaseBrokerExecutableFileSystemStub()
        fileSystem.descriptorFlagValues = [0]

        #expect(throws: DatabaseBrokerExecutableLauncherError.executableUnsafe) {
            try DatabaseBrokerExecutableResolver(
                fileSystem: fileSystem,
                codeSigningSystem: DatabaseBrokerExecutableCodeSigningSystemStub()
            ).resolveCurrent()
        }
    }

    @Test func rejectsPathThatDoesNotNameTheOpenedInode() {
        let fileSystem = DatabaseBrokerExecutableFileSystemStub()
        fileSystem.pathMetadataValues = [
            DatabaseBrokerExecutableLauncherTestValues.replacementMetadata
        ]

        #expect(throws: DatabaseBrokerExecutableLauncherError.executableReplaced) {
            try DatabaseBrokerExecutableResolver(
                fileSystem: fileSystem,
                codeSigningSystem: DatabaseBrokerExecutableCodeSigningSystemStub()
            ).resolveCurrent()
        }
    }

    @Test func rejectsReplacementDuringCodeValidationAndClosesDescriptor() {
        let fileSystem = DatabaseBrokerExecutableFileSystemStub()
        let codeSigningSystem = DatabaseBrokerExecutableCodeSigningSystemStub()
        codeSigningSystem.candidateValidationAction = {
            fileSystem.pathMetadataValues = [
                DatabaseBrokerExecutableLauncherTestValues.replacementMetadata
            ]
        }

        #expect(throws: DatabaseBrokerExecutableLauncherError.executableReplaced) {
            try DatabaseBrokerExecutableResolver(
                fileSystem: fileSystem,
                codeSigningSystem: codeSigningSystem
            ).resolveCurrent()
        }
        #expect(fileSystem.calls.last == .close(fileSystem.descriptor))
    }

    @Test(
        arguments: [
            DatabaseBrokerExecutableCodeSigningSystemStub.Failure.currentCode,
            .currentStaticCode,
            .designatedRequirement,
            .currentValidation,
            .currentUniqueIdentifier,
            .candidateStaticCode,
            .candidateValidation,
            .candidateUniqueIdentifier,
        ])
    fileprivate func mapsCodeSigningFailures(
        failure: DatabaseBrokerExecutableCodeSigningSystemStub.Failure
    ) {
        let codeSigningSystem = DatabaseBrokerExecutableCodeSigningSystemStub()
        codeSigningSystem.failure = failure
        let expectedError: DatabaseBrokerExecutableLauncherError
        switch failure {
        case .currentCode:
            expectedError = .currentCodeUnavailable
        case .currentStaticCode:
            expectedError = .currentStaticCodeUnavailable
        case .designatedRequirement:
            expectedError = .currentDesignatedRequirementUnavailable
        case .currentValidation:
            expectedError = .currentCodeInvalid
        case .currentUniqueIdentifier:
            expectedError = .currentUniqueIdentifierUnavailable
        case .candidateStaticCode:
            expectedError = .candidateStaticCodeUnavailable
        case .candidateValidation:
            expectedError = .candidateCodeInvalid
        case .candidateUniqueIdentifier:
            expectedError = .candidateUniqueIdentifierUnavailable
        }

        #expect(throws: expectedError) {
            try DatabaseBrokerExecutableResolver(
                fileSystem: DatabaseBrokerExecutableFileSystemStub(),
                codeSigningSystem: codeSigningSystem
            ).resolveCurrent()
        }
    }

    @Test func rejectsEmptyOrDifferentUniqueIdentifiers() {
        let emptySystem = DatabaseBrokerExecutableCodeSigningSystemStub()
        emptySystem.uniqueIdentifiers[.current] = Data()
        #expect(
            throws: DatabaseBrokerExecutableLauncherError
                .currentUniqueIdentifierUnavailable
        ) {
            try DatabaseBrokerExecutableResolver(
                fileSystem: DatabaseBrokerExecutableFileSystemStub(),
                codeSigningSystem: emptySystem
            ).resolveCurrent()
        }

        let differentSystem = DatabaseBrokerExecutableCodeSigningSystemStub()
        differentSystem.uniqueIdentifiers[.candidate] = Data([0x40])
        #expect(
            throws: DatabaseBrokerExecutableLauncherError
                .candidateUniqueIdentifierMismatch
        ) {
            try DatabaseBrokerExecutableResolver(
                fileSystem: DatabaseBrokerExecutableFileSystemStub(),
                codeSigningSystem: differentSystem
            ).resolveCurrent()
        }
    }
}

@Suite struct DatabaseBrokerExecutableLauncherTests {
    @Test func launchesExactMachOWithSanitizedDetachedProcessContract() throws {
        let fileSystem = DatabaseBrokerExecutableFileSystemStub()
        let codeSigningSystem = DatabaseBrokerExecutableCodeSigningSystemStub()
        let processSystem = DatabaseBrokerProcessSpawningSystemStub()
        let resolver = DatabaseBrokerExecutableResolver(
            fileSystem: fileSystem,
            codeSigningSystem: codeSigningSystem)
        let spawner = DatabaseBrokerProcessSpawner(
            system: processSystem,
            environment: [
                "HOME": "/Users/test",
                "TMPDIR": "/private/tmp/test",
                "USER": "test",
                "LOGNAME": "test",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "LC_COLLATE": "en_US.UTF-8",
                "LC_CTYPE": "UTF-8",
                "LC_MESSAGES": "en_US.UTF-8",
                "LC_MONETARY": "en_US.UTF-8",
                "LC_NUMERIC": "en_US.UTF-8",
                "LC_TIME": "en_US.UTF-8",
                "LC_DATABASE_PASSWORD": "secret",
                "LC-bad": "rejected",
                "PATH": "/attacker/bin",
                "EDITH_CLI": "1",
                "EDITH_DATABASE_BROKER": "attacker",
                "DATABASE_URL": "postgres://secret",
                "AWS_SECRET_ACCESS_KEY": "secret",
            ])
        let launcher = try DatabaseBrokerExecutableLauncher(
            resolver: resolver,
            spawner: spawner)

        try launcher.launch()

        let request = try #require(processSystem.requests.first)
        #expect(processSystem.requests.count == 1)
        #expect(request.executablePath == fileSystem.canonicalPath)
        #expect(request.arguments == [fileSystem.canonicalPath])
        #expect(
            request.environment == [
                "HOME": "/Users/test",
                "TMPDIR": "/private/tmp/test",
                "USER": "test",
                "LOGNAME": "test",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "LC_COLLATE": "en_US.UTF-8",
                "LC_CTYPE": "UTF-8",
                "LC_MESSAGES": "en_US.UTF-8",
                "LC_MONETARY": "en_US.UTF-8",
                "LC_NUMERIC": "en_US.UTF-8",
                "LC_TIME": "en_US.UTF-8",
                "EDITH_DATABASE_BROKER": "1",
            ])
        #expect(
            request.flags
                == Int16(
                    POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID
                        | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        #expect(
            request.defaultSignals
                == Set(
                    (Int32(1)..<Int32(NSIG)).filter { signal in
                        signal != SIGKILL && signal != SIGSTOP
                    }))
        #expect(request.signalMask.isEmpty)
        #expect(request.standardInputPath == "/dev/null")
        #expect(request.standardOutputPath == "/dev/null")
        #expect(request.standardErrorPath == "/dev/null")
        #expect(processSystem.reapedProcessIdentifiers == [processSystem.processIdentifier])
        #expect(
            fileSystem.calls.suffix(3) == [
                .descriptorMetadata(fileSystem.descriptor),
                .pathMetadata(fileSystem.canonicalPath),
                .descriptorFlags(fileSystem.descriptor),
            ])
    }

    @Test func replacementImmediatelyBeforeSpawnPreventsLaunchAndReaping() throws {
        let fileSystem = DatabaseBrokerExecutableFileSystemStub()
        fileSystem.pathMetadataValues = [
            DatabaseBrokerExecutableLauncherTestValues.metadata,
            DatabaseBrokerExecutableLauncherTestValues.metadata,
            DatabaseBrokerExecutableLauncherTestValues.replacementMetadata,
        ]
        let processSystem = DatabaseBrokerProcessSpawningSystemStub()
        let launcher = try DatabaseBrokerExecutableLauncher(
            resolver: DatabaseBrokerExecutableResolver(
                fileSystem: fileSystem,
                codeSigningSystem: DatabaseBrokerExecutableCodeSigningSystemStub()),
            spawner: DatabaseBrokerProcessSpawner(system: processSystem, environment: [:]))

        #expect(throws: DatabaseBrokerExecutableLauncherError.executableReplaced) {
            try launcher.launch()
        }
        #expect(processSystem.requests.isEmpty)
        #expect(processSystem.reapedProcessIdentifiers.isEmpty)
    }

    @Test func spawnFailureDoesNotRegisterReaper() throws {
        let processSystem = DatabaseBrokerProcessSpawningSystemStub()
        processSystem.failsSpawn = true
        let launcher = try DatabaseBrokerExecutableLauncher(
            resolver: DatabaseBrokerExecutableResolver(
                fileSystem: DatabaseBrokerExecutableFileSystemStub(),
                codeSigningSystem: DatabaseBrokerExecutableCodeSigningSystemStub()),
            spawner: DatabaseBrokerProcessSpawner(system: processSystem, environment: [:]))

        #expect(throws: DatabaseBrokerExecutableLauncherError.spawnFailed) {
            try launcher.launch()
        }
        #expect(processSystem.requests.count == 1)
        #expect(processSystem.reapedProcessIdentifiers.isEmpty)
    }

    @Test func rejectsMalformedAllowedEnvironmentValues() throws {
        let processSystem = DatabaseBrokerProcessSpawningSystemStub()
        let executable = try DatabaseBrokerExecutableResolver(
            fileSystem: DatabaseBrokerExecutableFileSystemStub(),
            codeSigningSystem: DatabaseBrokerExecutableCodeSigningSystemStub()
        ).resolveCurrent()
        let spawner = DatabaseBrokerProcessSpawner(
            system: processSystem,
            environment: [
                "LC_GOOD": "value",
                "LC_LOWERcase": "rejected",
                "LC_DATABASE_PASSWORD": "secret",
                "LC_NULL": "bad\0value",
                "LC_É": "rejected",
                "LANG": "en_US.UTF-8",
            ])

        try spawner.spawn(executable)

        let request = try #require(processSystem.requests.first)
        #expect(
            request.environment == [
                "LANG": "en_US.UTF-8",
                "EDITH_DATABASE_BROKER": "1",
            ])
    }
}
