import Darwin
import Foundation
import Testing
@testable import ExtensionMarketplace

struct ExtensionPackageFilesystemTests {
    @Test(arguments: [0, 1, 2, 3, 4])
    func linkedPackageAncestorsRejectRemovalPruningAndReplacement(_ depth: Int) async throws {
        for action in ["remove", "prune", "replace"] {
            let fixture = try PackageFixture()
            defer { fixture.clean() }
            let (package, archive) = try fixture.archive()
            _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
                [package], repository: "example/app")
            if action == "prune" {
                try fixture.store.commit([
                    package,
                    fixturePackage(package.id, version: "2.0.0"),
                    fixturePackage(package.id, version: "3.0.0"),
                ])
            }
            if action == "replace" { try fixture.store.commit([]) }
            var ancestor = fixture.store.root
            for component in [package.id, package.hostABI, package.architecture, package.version]
                .prefix(depth)
            {
                ancestor.appendPathComponent(component)
            }
            let data = fixture.directory.appendingPathComponent("Data")
            try FileManager.default.moveItem(at: ancestor, to: data)
            let sentinel = data.appendingPathComponent("retained-user-data")
            let bytes = Data("synthetic persistent history".utf8)
            try bytes.write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: data)
            switch action {
            case "remove":
                #expect(throws: (any Error).self) { try fixture.store.remove(id: package.id) }
            case "prune":
                #expect(throws: (any Error).self) { try fixture.store.prune(hostABI: "host-1") }
            default:
                await #expect(throws: (any Error).self) {
                    try await fixture.installer(archives: [package.downloadURL: archive]).install(
                        [package], repository: "example/app")
                }
            }
            #expect(try Data(contentsOf: sentinel) == bytes)
            let originalPayload = data.appendingPathComponent(
                Array(
                    [package.id, package.hostABI, package.architecture, package.version].dropFirst(
                        depth)
                )
                .joined(separator: "/")
            )
            .appendingPathComponent(package.id).appendingPathComponent("package.json")
            #expect(FileManager.default.fileExists(atPath: originalPayload.path))
        }
    }

    @Test(arguments: [0, 1])
    func failedMultiVersionRemovalCommitsRemovalAndRetriesCleanupAfterRestart(_ failingIndex: Int)
        async throws
    {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let first = try fixture.archive("1.0.0")
        let second = try fixture.archive("2.0.0")
        let packages = [first.0, second.0]
        for (package, archive) in [first, second] {
            _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
                [package], repository: "example/app")
        }
        try fixture.store.select(second.0)
        let selected = fixture.store.root.appendingPathComponent("selected-packages.json")
        let blocked = fixture.store.directory(for: packages[failingIndex])
            .appendingPathComponent(packages[failingIndex].id)
            .appendingPathComponent("helper.bundle/Contents/MacOS")
        #expect(chmod(blocked.path, 0o500) == 0)
        #expect(throws: (any Error).self) { try fixture.store.remove(id: first.0.id) }
        #expect(try fixture.store.installedPackages().isEmpty)
        #expect(
            try JSONDecoder().decode([ExtensionPackage].self, from: Data(contentsOf: selected))
                .isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.store.directory(for: packages[failingIndex]).path))
        if failingIndex == 1 {
            #expect(
                !FileManager.default.fileExists(atPath: fixture.store.directory(for: first.0).path))
        }
        #expect(chmod(blocked.path, 0o700) == 0)
        let restarted = ExtensionPackageStore(root: fixture.store.root)
        try restarted.recoverPackageDeletions()
        #expect(try restarted.installedPackages().isEmpty)
        for package in packages {
            #expect(!FileManager.default.fileExists(atPath: restarted.directory(for: package).path))
        }
        #expect(
            try JSONDecoder().decode([ExtensionPackage].self, from: Data(contentsOf: selected))
                .isEmpty)
        #expect(try restarted.remove(id: first.0.id) == false)
    }

    @Test func absentPayloadsCompleteRemovalAndPruningIdempotently() throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let packages = ["1.0.0", "2.0.0", "3.0.0"].map { fixturePackage("keepAwake", version: $0) }
        try fixture.store.commit(packages)
        try fixture.store.prune(hostABI: "host-1")
        #expect(try fixture.store.installedPackages() == Array(packages.dropFirst()))
        #expect(try fixture.store.remove(id: "keepAwake"))
        #expect(try fixture.store.installedPackages().isEmpty)
    }

    @Test(arguments: [false, true])
    func writableRootAndDescendantsAreRejected(_ descendant: Bool) async throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let (package, archive) = try fixture.archive()
        _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "example/app")
        let target =
            descendant ? fixture.store.root.appendingPathComponent(package.id) : fixture.store.root
        #expect(chmod(target.path, 0o777) == 0)
        #expect(throws: MarketplaceError.invalidArchive) {
            try fixture.store.remove(id: package.id)
        }
        #expect(chmod(target.path, 0o700) == 0)
        #expect(try fixture.store.installedPackages() == [package])
        #expect(FileManager.default.fileExists(atPath: fixture.store.directory(for: package).path))
    }

    @Test func deletionKeepsPinnedParentAuthorityAcrossSubstitution() async throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let (package, archive) = try fixture.archive()
        _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "example/app")
        let authority = try PackageDirectory(fixture.store.root, create: false)
        let parent = try #require(try authority.parent(package))
        let original = fixture.store.directory(for: package).deletingLastPathComponent()
        let detached = fixture.directory.appendingPathComponent("detached-packages")
        try FileManager.default.moveItem(at: original, to: detached)
        let data = fixture.directory.appendingPathComponent("Data")
        let foreign = data.appendingPathComponent(package.version)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let sentinel = foreign.appendingPathComponent("history")
        let bytes = Data("synthetic retained history".utf8)
        try bytes.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: data)
        try parent.removeTree(package.version)
        #expect(
            !FileManager.default.fileExists(
                atPath: detached.appendingPathComponent(package.version).path))
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(throws: (any Error).self) { try authority.remove(package) }
    }

    @Test func payloadLinksAreUnlinkedWithoutFollowingTheirTargets() async throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let (package, archive) = try fixture.archive()
        _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "example/app")
        let sentinel = fixture.directory.appendingPathComponent("history")
        let bytes = Data("synthetic user history".utf8)
        try bytes.write(to: sentinel)
        let link = fixture.store.directory(for: package).appendingPathComponent("retained-data")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
        #expect(try fixture.store.remove(id: package.id))
        #expect(try fixture.store.installedPackages().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(for: package).path))
        #expect(try Data(contentsOf: sentinel) == bytes)
    }

    @Test func descriptorCopyPreservesExecutableModesAndSealedResourceBytes() throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let package = fixturePackage()
        let source = fixture.directory.appendingPathComponent("staged")
        let payload = source.appendingPathComponent(package.id)
        let bundle = payload.appendingPathComponent("helper.bundle")
        let executable = bundle.appendingPathComponent("Contents/MacOS/Runtime")
        let seal = bundle.appendingPathComponent("Contents/_CodeSignature/CodeResources")
        for file in [executable, seal] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let executableBytes = Data("synthetic executable bytes".utf8)
        let sealBytes = Data("synthetic sealed resource bytes".utf8)
        try executableBytes.write(to: executable)
        try sealBytes.write(to: seal)
        #expect(chmod(executable.path, 0o755) == 0)
        #expect(chmod(bundle.path, 0o755) == 0)
        let authority = try PackageDirectory(fixture.store.root, create: true)
        try authority.install(package, from: source)
        let installedBundle = fixture.store.directory(for: package)
            .appendingPathComponent(package.id).appendingPathComponent("helper.bundle")
        let installedExecutable = installedBundle.appendingPathComponent("Contents/MacOS/Runtime")
        #expect(try Data(contentsOf: installedExecutable) == executableBytes)
        #expect(
            try Data(
                contentsOf: installedBundle.appendingPathComponent(
                    "Contents/_CodeSignature/CodeResources")) == sealBytes)
        var mode = stat()
        #expect(stat(installedExecutable.path, &mode) == 0)
        #expect(mode.st_mode & 0o777 == 0o755)
        #expect(stat(installedBundle.path, &mode) == 0)
        #expect(mode.st_mode & 0o777 == 0o755)
        try authority.remove(package)
    }

    @Test func pendingDeletionFailureCommitsRemovalBeforeRestartCleanup() async throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let (package, archive) = try fixture.archive()
        _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "example/app")
        let lease = try fixture.store.lease(package)
        #expect(try fixture.store.requestRemoval(id: package.id) == false)
        lease.close()
        let blocked = fixture.store.directory(for: package)
            .appendingPathComponent(package.id).appendingPathComponent(
                "helper.bundle/Contents/MacOS")
        #expect(chmod(blocked.path, 0o500) == 0)
        #expect(throws: (any Error).self) { try fixture.store.completePendingRemovals() }
        #expect(try fixture.store.installedPackages().isEmpty)
        #expect(try fixture.store.pendingRemovals() == [package.id])
        #expect(chmod(blocked.path, 0o700) == 0)
        let restarted = ExtensionPackageStore(root: fixture.store.root)
        try restarted.completePendingRemovals()
        #expect(try restarted.installedPackages().isEmpty)
        #expect(try restarted.pendingRemovals().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: restarted.directory(for: package).path))
    }

    @Test func replacementWaitsForAnExistingLeaseAndKeepsPayloadOnVerificationFailure() async throws
    {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let (package, archive) = try fixture.archive()
        _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "example/app")
        try fixture.store.commit([])
        let payload = fixture.store.directory(for: package)
            .appendingPathComponent(package.id).appendingPathComponent("package.json")
        let bytes = try Data(contentsOf: payload)
        let lease = try fixture.store.lease(package)
        await #expect(throws: MarketplaceError.packageBusy) {
            try await fixture.installer(archives: [package.downloadURL: archive]).install(
                [package], repository: "example/app")
        }
        lease.close()
        await #expect(throws: MarketplaceError.invalidSignature) {
            try await fixture.installer(
                archives: [package.downloadURL: archive], rejectsSignature: true
            ).install(
                [package], repository: "example/app")
        }
        #expect(try Data(contentsOf: payload) == bytes)
        _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "example/app")
        #expect(try fixture.store.installedPackages() == [package])
        #expect(try Data(contentsOf: payload) == bytes)
    }

    @Test func rootSubstitutionDuringRollbackCannotDeletePersistentData() async throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let (first, firstArchive) = try fixture.archive()
        let (second, _) = try fixture.archive(id: "calendar")
        let detached = fixture.directory.appendingPathComponent("detached-root")
        let data = fixture.directory.appendingPathComponent("Data")
        let foreign = data.appendingPathComponent(first.id)
            .appendingPathComponent(first.hostABI).appendingPathComponent(first.architecture)
            .appendingPathComponent(first.version)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let sentinel = foreign.appendingPathComponent("history")
        let bytes = Data("synthetic history retained on rollback".utf8)
        try bytes.write(to: sentinel)
        let installer = ExtensionPackageInstaller(
            store: fixture.store,
            download: { url, _ in
                if url == first.downloadURL {
                    let copy = fixture.directory.appendingPathComponent("downloaded.zip")
                    try FileManager.default.copyItem(at: firstArchive, to: copy)
                    return copy
                }
                try FileManager.default.moveItem(at: fixture.store.root, to: detached)
                try FileManager.default.createSymbolicLink(
                    at: fixture.store.root, withDestinationURL: data)
                throw MarketplaceError.downloadFailed
            }, verify: { _ in })
        await #expect(throws: MarketplaceError.downloadFailed) {
            try await installer.install([first, second], repository: "example/app")
        }
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(
            !FileManager.default.fileExists(
                atPath: detached.appendingPathComponent(first.id)
                    .appendingPathComponent(first.hostABI).appendingPathComponent(
                        first.architecture
                    )
                    .appendingPathComponent(first.version).path))
        #expect(
            !FileManager.default.fileExists(
                atPath: data.appendingPathComponent("installed.json").path))
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func ancestorSubstitutionDuringDownloadCannotWriteOutsideThePinnedStore(_ depth: Int)
        async throws
    {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let (package, archive) = try fixture.archive()
        let components = [package.id, package.hostABI, package.architecture, package.version]
        let data = fixture.directory.appendingPathComponent("Data")
        let target = components.dropFirst(depth).reduce(data) { $0.appendingPathComponent($1) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("history")
        let bytes = Data("synthetic data outside package authority".utf8)
        try bytes.write(to: sentinel)
        let detached = fixture.directory.appendingPathComponent("detached-download-root")
        let installer = ExtensionPackageInstaller(
            store: fixture.store,
            download: { _, _ in
                let ancestor = components.prefix(depth).reduce(fixture.store.root) {
                    $0.appendingPathComponent($1)
                }
                try FileManager.default.createDirectory(
                    at: ancestor, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: ancestor, to: detached)
                try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: data)
                let copy = fixture.directory.appendingPathComponent("downloaded.zip")
                try FileManager.default.copyItem(at: archive, to: copy)
                return copy
            }, verify: { _ in })
        await #expect(throws: (any Error).self) {
            try await installer.install([package], repository: "example/app")
        }
        #expect(try Data(contentsOf: sentinel) == bytes)
        let files = try #require(
            FileManager.default.enumerator(
                at: data, includingPropertiesForKeys: [.isRegularFileKey]))
        var regularFiles: [URL] = []
        for file in files.allObjects.compactMap({ $0 as? URL }) {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                regularFiles.append(file)
            }
        }
        #expect(
            regularFiles.map { $0.resolvingSymlinksInPath() }
                == [sentinel.resolvingSymlinksInPath()])
        #expect(
            !FileManager.default.fileExists(atPath: target.appendingPathComponent(package.id).path))
        if depth == 0 {
            #expect(
                !FileManager.default.fileExists(
                    atPath: components.reduce(detached) {
                        $0.appendingPathComponent($1)
                    }.path))
        } else {
            #expect(try fixture.store.installedPackages().isEmpty)
        }
    }

    @Test func linkedLeaseStorageIsRejectedInsteadOfSilentlySkippingPruning() throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let packages = ["1.0.0", "2.0.0", "3.0.0"].map { fixturePackage("keepAwake", version: $0) }
        try fixture.store.commit(packages)
        let outside = fixture.directory.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: fixture.store.root.appendingPathComponent(".leases"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try fixture.store.prune(hostABI: "host-1") }
        #expect(try fixture.store.installedPackages() == packages)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func nonregularPackageFilesAreRejectedWithoutBlocking() throws {
        let environmentKey = "EXTENSION_PACKAGE_FIFO_PROBE"
        if let target = ProcessInfo.processInfo.environment[environmentKey] {
            alarm(3)
            defer { alarm(0) }
            let fixture = try PackageFixture()
            defer { fixture.clean() }
            let package = fixturePackage()
            try fixture.store.commit([package])
            let fifo: URL
            switch target {
            case "installed":
                fifo = fixture.store.root.appendingPathComponent("installed.json")
                try FileManager.default.removeItem(at: fifo)
            case "selected":
                fifo = fixture.store.root.appendingPathComponent("selected-packages.json")
            case "pending":
                fifo = fixture.store.root.appendingPathComponent("pending-removals.json")
            case "operation":
                fifo = fixture.store.root.appendingPathComponent(".operation.lock")
            case "lease":
                fifo = fixture.store.leaseURL(for: package)
                try FileManager.default.createDirectory(
                    at: fifo.deletingLastPathComponent(), withIntermediateDirectories: false)
            case "copy":
                fifo = fixture.directory.appendingPathComponent("staged/special-file")
                try FileManager.default.createDirectory(
                    at: fifo.deletingLastPathComponent(), withIntermediateDirectories: false)
            default:
                throw MarketplaceError.invalidCatalog
            }
            #expect(mkfifo(fifo.path, 0o600) == 0)
            switch target {
            case "installed":
                #expect(throws: MarketplaceError.invalidArchive) {
                    try fixture.store.installedPackages()
                }
            case "selected":
                #expect(throws: MarketplaceError.invalidArchive) {
                    try fixture.store.installedPackage(
                        id: package.id, hostABI: package.hostABI, architecture: package.architecture
                    )
                }
            case "pending":
                #expect(throws: MarketplaceError.invalidArchive) {
                    try fixture.store.pendingRemovals()
                }
            case "operation":
                #expect(throws: MarketplaceError.invalidArchive) {
                    try fixture.store.remove(id: package.id)
                }
            case "lease":
                #expect(throws: MarketplaceError.invalidArchive) {
                    try fixture.store.lease(package)
                }
            default:
                #expect(throws: MarketplaceError.invalidArchive) {
                    try PackageDirectory(fixture.store.root, create: false).install(
                        package, from: fifo.deletingLastPathComponent())
                }
                #expect(
                    !FileManager.default.fileExists(
                        atPath: fixture.store.directory(for: package).path))
            }
            var info = stat()
            #expect(lstat(fifo.path, &info) == 0)
            #expect(info.st_mode & S_IFMT == S_IFIFO)
            return
        }
        for target in ["installed", "selected", "pending", "operation", "lease", "copy"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            var arguments = Array(CommandLine.arguments.dropFirst())
            if let filter = arguments.firstIndex(of: "--filter"), filter + 1 < arguments.count {
                arguments[filter + 1] = "nonregularPackageFilesAreRejectedWithoutBlocking"
            } else {
                arguments += ["--filter", "nonregularPackageFilesAreRejectedWithoutBlocking"]
            }
            child.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment[environmentKey] = target
            child.environment = environment
            let output = Pipe()
            child.standardOutput = output
            child.standardError = output
            try child.run()
            let deadline = ContinuousClock.now + .seconds(5)
            while child.isRunning, ContinuousClock.now < deadline { usleep(10_000) }
            let timedOut = child.isRunning
            if timedOut { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            let captured = try output.fileHandleForReading.readToEnd() ?? Data()
            let result = String(decoding: captured, as: UTF8.self)
            #expect(!timedOut, "FIFO probe timed out: \(target)")
            #expect(
                result.contains("Test nonregularPackageFilesAreRejectedWithoutBlocking() passed"),
                "FIFO probe did not complete its selected test: \(target): \(result)")
            #expect(child.terminationReason == .exit, "FIFO probe terminated: \(target): \(result)")
            #expect(child.terminationStatus == 0, "FIFO probe failed: \(target): \(result)")
        }
    }

}
