import Darwin
import Foundation

public enum AppMaintenanceInstallDestination: String, CaseIterable, Sendable {
    case user = "user"
    case system = "system"

    public var title: String {
        switch self {
        case .user: "My Applications"
        case .system: "All Users"
        }
    }

    public func root(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        switch self {
        case .user: home.appendingPathComponent("Applications", isDirectory: true)
        case .system: URL(fileURLWithPath: "/Applications", isDirectory: true)
        }
    }
}

public struct AppMaintenanceDiskImageAttachment: Equatable, Sendable {
    public let mountURL: URL
    public let deviceEntry: String

    public init(mountURL: URL, deviceEntry: String) {
        self.mountURL = mountURL
        self.deviceEntry = deviceEntry
    }
}

public struct AppMaintenanceDiskImagePlan: Identifiable, Equatable, Sendable {
    public let imageURL: URL
    public let imageIdentity: AppMaintenanceFileIdentity
    public let imageSizeBytes: Int64
    public let mountURL: URL
    public let mountIdentity: AppMaintenanceFileIdentity
    public let deviceEntry: String
    public let sourceApplication: InstalledApplication
    public let sourceIdentity: AppMaintenanceFileIdentity
    public let sourceInfoIdentity: AppMaintenanceFileIdentity
    public let destination: AppMaintenanceInstallDestination
    public let destinationRoot: URL
    public let destinationRootIdentity: AppMaintenanceFileIdentity?
    public let destinationURL: URL
    public let existingApplication: InstalledApplication?
    public let existingIdentity: AppMaintenanceFileIdentity?
    public let existingInfoIdentity: AppMaintenanceFileIdentity?

    public var id: String { imageURL.path }
    public var replacesExisting: Bool { existingApplication != nil }
}

public struct AppMaintenanceInstallResult: Equatable, Sendable {
    public let applicationURL: URL
    public let replacedExisting: Bool
    public let ejected: Bool
    public let imageMovedToTrash: Bool

    public init(
        applicationURL: URL, replacedExisting: Bool, ejected: Bool,
        imageMovedToTrash: Bool
    ) {
        self.applicationURL = applicationURL
        self.replacedExisting = replacedExisting
        self.ejected = ejected
        self.imageMovedToTrash = imageMovedToTrash
    }
}

public enum AppMaintenanceDiskImageError: LocalizedError, Equatable, Sendable {
    case invalidDiskImage
    case mountFailed
    case invalidMount
    case singleApplicationRequired(Int)
    case invalidApplication
    case protectedApplication
    case verificationFailed
    case destinationConflict
    case replacementRequiresConfirmation
    case reviewedSourceChanged
    case reviewedDestinationChanged
    case stagingFailed
    case installationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDiskImage:
            "Choose a regular .dmg file that has not changed or become a symbolic link."
        case .mountFailed:
            "The disk image could not be mounted read-only."
        case .invalidMount:
            "The mounted volume could not be tied safely to this disk image."
        case .singleApplicationRequired(let count):
            "The disk image must contain exactly one top-level app. Found \(count)."
        case .invalidApplication:
            "The disk image does not contain a valid application bundle."
        case .protectedApplication:
            "Edith and Apple system applications cannot be installed here."
        case .verificationFailed:
            "The application failed code-signing or Gatekeeper verification."
        case .destinationConflict:
            "A different application already uses this destination name."
        case .replacementRequiresConfirmation:
            "Confirm that the existing application should move to the Trash."
        case .reviewedSourceChanged:
            "The disk image or mounted application changed after review. Choose it again."
        case .reviewedDestinationChanged:
            "The destination changed after review. Choose the disk image again."
        case .stagingFailed:
            "The application could not be copied into a verified staging area."
        case .installationFailed:
            "The verified application could not be moved into Applications."
        }
    }
}

public enum AppMaintenanceDiskImageInstaller {
    public typealias RunCommand =
        @Sendable (CLICommandRequest) async throws -> CLICommandResult
    public typealias TrashItem = @Sendable (URL) throws -> URL?

    public static func plan(
        imageURL: URL, destination: AppMaintenanceInstallDestination = .user,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        destinationRoot: URL? = nil,
        run: @escaping RunCommand = liveRun
    ) async throws -> AppMaintenanceDiskImagePlan {
        let imageURL = imageURL.standardizedFileURL
        guard imageURL.pathExtension.caseInsensitiveCompare("dmg") == .orderedSame,
            !isSymbolicLink(imageURL), let imageIdentity = regularFileIdentity(at: imageURL)
        else { throw AppMaintenanceDiskImageError.invalidDiskImage }
        let imageSize = fileSize(at: imageURL)
        let mountURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-disk-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mountURL, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var mountedAttachment: AppMaintenanceDiskImageAttachment?
        do {
            let attachResult = try await command(
                "/usr/bin/hdiutil",
                [
                    "attach", "-readonly", "-nobrowse", "-plist", "-mountpoint",
                    mountURL.path, imageURL.path,
                ], timeout: 90, run: run)
            guard attachResult.terminationStatus == 0 else {
                throw AppMaintenanceDiskImageError.mountFailed
            }
            mountedAttachment = AppMaintenanceDiskImageAttachment(
                mountURL: mountURL, deviceEntry: mountURL.path)
            guard
                let parsed = attachment(
                    from: attachResult.outputData, requestedMount: mountURL),
                parsed.mountURL == normalizedURL(mountURL),
                parsed.deviceEntry.hasPrefix("/dev/"),
                let mountIdentity = directoryIdentity(at: parsed.mountURL)
            else { throw AppMaintenanceDiskImageError.invalidMount }
            mountedAttachment = parsed
            let applicationURLs = topLevelApplications(in: parsed.mountURL)
            guard applicationURLs.count == 1, let sourceURL = applicationURLs.first else {
                throw AppMaintenanceDiskImageError.singleApplicationRequired(
                    applicationURLs.count)
            }
            let source = try inspectedApplication(at: sourceURL)
            guard
                !AppMaintenanceInventory.isProtected(
                    bundleID: source.application.bundleID, url: sourceURL)
            else { throw AppMaintenanceDiskImageError.protectedApplication }
            guard await gatekeeperAccepts(sourceURL, run: run) else {
                throw AppMaintenanceDiskImageError.verificationFailed
            }
            let requestedRoot = destinationRoot ?? destination.root(home: home)
            guard !isSymbolicLink(requestedRoot) else {
                throw AppMaintenanceDiskImageError.invalidApplication
            }
            let root = normalizedURL(requestedRoot)
            let rootIdentity = directoryIdentity(at: root)
            guard let destinationURL = destinationURL(for: sourceURL, root: root) else {
                throw AppMaintenanceDiskImageError.invalidApplication
            }
            var existingApplication: InstalledApplication?
            var existingIdentity: AppMaintenanceFileIdentity?
            var existingInfoIdentity: AppMaintenanceFileIdentity?
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let existing = try inspectedApplication(at: destinationURL)
                guard existing.application.bundleID == source.application.bundleID else {
                    throw AppMaintenanceDiskImageError.destinationConflict
                }
                existingApplication = existing.application
                existingIdentity = existing.identity
                existingInfoIdentity = existing.infoIdentity
            }
            return AppMaintenanceDiskImagePlan(
                imageURL: imageURL, imageIdentity: imageIdentity, imageSizeBytes: imageSize,
                mountURL: parsed.mountURL, mountIdentity: mountIdentity,
                deviceEntry: parsed.deviceEntry, sourceApplication: source.application,
                sourceIdentity: source.identity, sourceInfoIdentity: source.infoIdentity,
                destination: destination, destinationRoot: root,
                destinationRootIdentity: rootIdentity, destinationURL: destinationURL,
                existingApplication: existingApplication, existingIdentity: existingIdentity,
                existingInfoIdentity: existingInfoIdentity)
        } catch {
            if let mountedAttachment {
                _ = await detach(mountedAttachment, run: run)
            } else {
                try? FileManager.default.removeItem(at: mountURL)
            }
            throw error
        }
    }

    public static func install(
        plan: AppMaintenanceDiskImagePlan, replaceExisting: Bool,
        moveImageToTrash: Bool = true, run: @escaping RunCommand = liveRun,
        trash: @escaping TrashItem = liveTrash
    ) async throws -> AppMaintenanceInstallResult {
        do {
            let result = try await performInstall(
                plan: plan, replaceExisting: replaceExisting,
                moveImageToTrash: moveImageToTrash, run: run, trash: trash)
            return result
        } catch {
            _ = await detach(
                AppMaintenanceDiskImageAttachment(
                    mountURL: plan.mountURL, deviceEntry: plan.deviceEntry), run: run)
            throw error
        }
    }

    public static func cancel(
        plan: AppMaintenanceDiskImagePlan, run: @escaping RunCommand = liveRun
    ) async {
        _ = await detach(
            AppMaintenanceDiskImageAttachment(
                mountURL: plan.mountURL, deviceEntry: plan.deviceEntry), run: run)
    }

    public static func attachment(
        from data: Data, requestedMount: URL
    ) -> AppMaintenanceDiskImageAttachment? {
        guard
            let document = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        let entities = document["system-entities"] as? [[String: Any]] ?? []
        let requested = normalizedURL(requestedMount)
        let matches = entities.compactMap { entity -> AppMaintenanceDiskImageAttachment? in
            guard let mountPath = entity["mount-point"] as? String,
                let deviceEntry = entity["dev-entry"] as? String,
                normalizedURL(URL(fileURLWithPath: mountPath, isDirectory: true)) == requested
            else { return nil }
            return AppMaintenanceDiskImageAttachment(
                mountURL: requested, deviceEntry: deviceEntry)
        }
        guard Set(matches.map(\.deviceEntry)).count == 1 else { return nil }
        return matches.first
    }

    public static func destinationURL(for applicationURL: URL, root: URL) -> URL? {
        let name = applicationURL.lastPathComponent
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
            !name.hasPrefix("."),
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        let root = normalizedURL(root)
        let destination = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard destination.deletingLastPathComponent() == root else { return nil }
        return destination
    }

    private struct InspectedApplication {
        let application: InstalledApplication
        let identity: AppMaintenanceFileIdentity
        let infoIdentity: AppMaintenanceFileIdentity
    }

    private static func performInstall(
        plan: AppMaintenanceDiskImagePlan, replaceExisting: Bool,
        moveImageToTrash: Bool, run: @escaping RunCommand,
        trash: @escaping TrashItem
    ) async throws -> AppMaintenanceInstallResult {
        guard regularFileIdentity(at: plan.imageURL) == plan.imageIdentity,
            fileSize(at: plan.imageURL) == plan.imageSizeBytes,
            directoryIdentity(at: plan.mountURL) == plan.mountIdentity,
            directoryIdentity(at: plan.sourceApplication.url) == plan.sourceIdentity,
            regularFileIdentity(
                at: plan.sourceApplication.url.appendingPathComponent("Contents/Info.plist"))
                == plan.sourceInfoIdentity,
            normalizedURL(plan.sourceApplication.url.deletingLastPathComponent())
                == normalizedURL(plan.mountURL)
        else { throw AppMaintenanceDiskImageError.reviewedSourceChanged }
        if let expectedRootIdentity = plan.destinationRootIdentity {
            guard directoryIdentity(at: plan.destinationRoot) == expectedRootIdentity else {
                throw AppMaintenanceDiskImageError.reviewedDestinationChanged
            }
        } else {
            guard !FileManager.default.fileExists(atPath: plan.destinationRoot.path),
                !isSymbolicLink(plan.destinationRoot)
            else { throw AppMaintenanceDiskImageError.reviewedDestinationChanged }
        }
        try prepareDestinationRoot(plan.destinationRoot)
        let destinationExists = FileManager.default.fileExists(atPath: plan.destinationURL.path)
        if let existingIdentity = plan.existingIdentity,
            let existingInfoIdentity = plan.existingInfoIdentity
        {
            guard destinationExists,
                directoryIdentity(at: plan.destinationURL) == existingIdentity,
                regularFileIdentity(
                    at: plan.destinationURL.appendingPathComponent("Contents/Info.plist"))
                    == existingInfoIdentity
            else { throw AppMaintenanceDiskImageError.reviewedDestinationChanged }
            guard replaceExisting else {
                throw AppMaintenanceDiskImageError.replacementRequiresConfirmation
            }
        } else if destinationExists {
            throw AppMaintenanceDiskImageError.reviewedDestinationChanged
        }
        let stagingDirectory: URL
        do {
            stagingDirectory = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: plan.destinationRoot, create: true)
        } catch {
            throw AppMaintenanceDiskImageError.stagingFailed
        }
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let stagedURL = stagingDirectory.appendingPathComponent(
            plan.sourceApplication.url.lastPathComponent, isDirectory: true)
        let copyResult = try await command(
            "/usr/bin/ditto",
            [
                "--rsrc", "--extattr", "--acl", "--qtn", plan.sourceApplication.url.path,
                stagedURL.path,
            ], timeout: 300, run: run)
        guard copyResult.terminationStatus == 0,
            let staged = try? inspectedApplication(at: stagedURL),
            staged.application.bundleID == plan.sourceApplication.bundleID
        else { throw AppMaintenanceDiskImageError.stagingFailed }
        guard await gatekeeperAccepts(stagedURL, run: run) else {
            throw AppMaintenanceDiskImageError.verificationFailed
        }
        var trashedExistingURL: URL?
        if destinationExists {
            do {
                trashedExistingURL = try trash(plan.destinationURL)
            } catch {
                throw AppMaintenanceDiskImageError.installationFailed
            }
        }
        do {
            try FileManager.default.moveItem(at: stagedURL, to: plan.destinationURL)
        } catch {
            if let trashedExistingURL,
                !FileManager.default.fileExists(atPath: plan.destinationURL.path)
            {
                try? FileManager.default.moveItem(
                    at: trashedExistingURL, to: plan.destinationURL)
            }
            throw AppMaintenanceDiskImageError.installationFailed
        }
        let ejected = await detach(
            AppMaintenanceDiskImageAttachment(
                mountURL: plan.mountURL, deviceEntry: plan.deviceEntry), run: run)
        var imageMovedToTrash = false
        if ejected, moveImageToTrash,
            regularFileIdentity(at: plan.imageURL) == plan.imageIdentity,
            fileSize(at: plan.imageURL) == plan.imageSizeBytes
        {
            imageMovedToTrash = (try? trash(plan.imageURL)) != nil
        }
        return AppMaintenanceInstallResult(
            applicationURL: plan.destinationURL, replacedExisting: destinationExists,
            ejected: ejected, imageMovedToTrash: imageMovedToTrash)
    }

    private static func topLevelApplications(in mountURL: URL) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: mountURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])) ?? []
        return entries.filter { url in
            guard normalizedURL(url.deletingLastPathComponent()) == normalizedURL(mountURL),
                url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey,
                ])
            else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private static func inspectedApplication(at url: URL) throws -> InspectedApplication {
        let url = normalizedURL(url)
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
            !isSymbolicLink(url), !isSymbolicLink(infoURL),
            let identity = directoryIdentity(at: url),
            let infoIdentity = regularFileIdentity(at: infoURL),
            let bundle = Bundle(url: url),
            let bundleID = AppMaintenanceInventory.verifiedBundleID(bundle.bundleIdentifier),
            let executableURL = bundle.executableURL,
            FileManager.default.isExecutableFile(atPath: executableURL.path),
            normalizedURL(executableURL).path.hasPrefix(url.path + "/")
        else { throw AppMaintenanceDiskImageError.invalidApplication }
        let name =
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let version =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "Unknown"
        return InspectedApplication(
            application: InstalledApplication(
                id: url.path, name: safeText(name), bundleID: bundleID,
                version: safeText(version), url: url),
            identity: identity, infoIdentity: infoIdentity)
    }

    private static func gatekeeperAccepts(
        _ applicationURL: URL, run: @escaping RunCommand
    ) async -> Bool {
        guard
            let signature = try? await command(
                "/usr/bin/codesign", ["--verify", "--deep", "--strict", applicationURL.path],
                timeout: 60, run: run), signature.terminationStatus == 0
        else { return false }
        if let status = try? await command(
            "/usr/sbin/spctl", ["--status"], timeout: 15, run: run),
            status.output.localizedCaseInsensitiveContains("disabled")
        {
            return true
        }
        guard
            let assessment = try? await command(
                "/usr/sbin/spctl", ["--assess", "--type", "execute", applicationURL.path],
                timeout: 60, run: run)
        else { return false }
        return assessment.terminationStatus == 0
    }

    private static func prepareDestinationRoot(_ root: URL) throws {
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
        }
        guard !isSymbolicLink(root), directoryIdentity(at: root) != nil else {
            throw AppMaintenanceDiskImageError.installationFailed
        }
    }

    private static func detach(
        _ attachment: AppMaintenanceDiskImageAttachment, run: @escaping RunCommand
    ) async -> Bool {
        let normal = try? await command(
            "/usr/bin/hdiutil", ["detach", attachment.deviceEntry], timeout: 60, run: run)
        var detached = normal?.terminationStatus == 0
        if !detached {
            let forced = try? await command(
                "/usr/bin/hdiutil", ["detach", "-force", attachment.deviceEntry],
                timeout: 60, run: run)
            detached = forced?.terminationStatus == 0
        }
        if detached { try? FileManager.default.removeItem(at: attachment.mountURL) }
        return detached
    }

    private static func command(
        _ executable: String, _ arguments: [String], timeout: TimeInterval,
        run: @escaping RunCommand
    ) async throws -> CLICommandResult {
        try await run(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: executable), arguments: arguments,
                environment: CLIToolEnvironment.sanitized(), timeout: timeout,
                maximumOutputBytes: 2 * 1_024 * 1_024, terminatesProcessGroup: true))
    }

    private static func normalizedURL(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            missing.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        return missing.reversed().reduce(existing.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.standardizedFileURL
    }

    private static func safeText(_ rawValue: String) -> String {
        let flattened = rawValue.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
        }
        let value = String(String.UnicodeScalarView(flattened)).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return value.isEmpty ? "Unknown" : String(value.prefix(120))
    }

    private static func fileSize(at url: URL) -> Int64 {
        let value = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(value ?? 0)
    }

    private static func directoryIdentity(at url: URL) -> AppMaintenanceFileIdentity? {
        identity(at: url, kind: S_IFDIR)
    }

    private static func regularFileIdentity(at url: URL) -> AppMaintenanceFileIdentity? {
        identity(at: url, kind: S_IFREG)
    }

    private static func identity(
        at url: URL, kind: mode_t
    ) -> AppMaintenanceFileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == kind else { return nil }
        return AppMaintenanceFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFLNK
    }

    public static let liveRun: RunCommand = { request in
        try await CLICommandRunner.run(request, onLine: { _ in })
    }

    public static let liveTrash: TrashItem = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}
