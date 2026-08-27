import Foundation
import Testing

@testable import EdithKit

private final class DiskImageCommandHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CLICommandRequest] = []
    private var mountedURLs: [URL] = []
    var applicationCount = 1
    var bundleID = "com.example.installer"
    var version = "2.0"
    var attachStatus: Int32 = 0
    var signatureStatus: Int32 = 0
    var assessmentStatus: Int32 = 0
    var assessmentsDisabled = false
    var detachStatus: Int32 = 0
    var validAttachment = true

    var recordedRequests: [CLICommandRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var recordedMounts: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return mountedURLs
    }

    func run(_ request: CLICommandRequest) throws -> CLICommandResult {
        lock.lock()
        requests.append(request)
        lock.unlock()
        switch request.executableURL.path {
        case "/usr/bin/hdiutil" where request.arguments.first == "attach":
            return try attach(request)
        case "/usr/bin/hdiutil" where request.arguments.first == "detach":
            if detachStatus == 0, let mount = recordedMounts.last {
                try? FileManager.default.removeItem(at: mount)
            }
            return CLICommandResult(terminationStatus: detachStatus, output: "")
        case "/usr/bin/codesign":
            return CLICommandResult(terminationStatus: signatureStatus, output: "")
        case "/usr/sbin/spctl" where request.arguments == ["--status"]:
            return CLICommandResult(
                terminationStatus: 0,
                output: assessmentsDisabled ? "assessments disabled" : "assessments enabled")
        case "/usr/sbin/spctl":
            return CLICommandResult(terminationStatus: assessmentStatus, output: "")
        case "/usr/bin/ditto":
            let source = URL(fileURLWithPath: request.arguments[request.arguments.count - 2])
            let destination = URL(fileURLWithPath: request.arguments.last!)
            try FileManager.default.copyItem(at: source, to: destination)
            return CLICommandResult(terminationStatus: 0, output: "")
        default:
            return CLICommandResult(terminationStatus: 127, output: "unexpected command")
        }
    }

    private func attach(_ request: CLICommandRequest) throws -> CLICommandResult {
        guard attachStatus == 0 else {
            return CLICommandResult(terminationStatus: attachStatus, output: "")
        }
        let mountIndex = try #require(request.arguments.firstIndex(of: "-mountpoint"))
        let requestedMount = URL(fileURLWithPath: request.arguments[mountIndex + 1])
        lock.lock()
        mountedURLs.append(requestedMount)
        lock.unlock()
        for index in 0..<applicationCount {
            let name = applicationCount == 1 ? "Example.app" : "Example\(index).app"
            try makeInstallerApplication(
                at: requestedMount.appendingPathComponent(name), bundleID: bundleID,
                version: version)
        }
        let reportedMount =
            validAttachment
            ? requestedMount.path : requestedMount.appendingPathComponent("Other").path
        let plist: [String: Any] = [
            "system-entities": [
                ["mount-point": reportedMount, "dev-entry": "/dev/disk99s1"]
            ]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        return CLICommandResult(terminationStatus: 0, outputData: data)
    }
}

private final class DiskImageTrashHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private var trashed: [URL] = []

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var items: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return trashed
    }

    func move(_ url: URL) throws -> URL? {
        lock.lock()
        trashed.append(url)
        lock.unlock()
        let destination = root.appendingPathComponent(
            "\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

@Suite struct AppMaintenanceDiskImageInstallerTests {
    @Test func attachmentRequiresTheExactRequestedMountAndOneDevice() throws {
        let mount = URL(fileURLWithPath: "/Volumes/Reviewed", isDirectory: true)
        let valid = try attachmentData([
            ["mount-point": mount.path, "dev-entry": "/dev/disk5s1"],
            ["dev-entry": "/dev/disk5"],
        ])
        #expect(
            AppMaintenanceDiskImageInstaller.attachment(from: valid, requestedMount: mount)
                == AppMaintenanceDiskImageAttachment(
                    mountURL: mount, deviceEntry: "/dev/disk5s1"))

        let mismatched = try attachmentData([
            ["mount-point": "/Volumes/Other", "dev-entry": "/dev/disk5s1"]
        ])
        #expect(
            AppMaintenanceDiskImageInstaller.attachment(
                from: mismatched, requestedMount: mount) == nil)

        let ambiguous = try attachmentData([
            ["mount-point": mount.path, "dev-entry": "/dev/disk5s1"],
            ["mount-point": mount.path, "dev-entry": "/dev/disk6s1"],
        ])
        #expect(
            AppMaintenanceDiskImageInstaller.attachment(
                from: ambiguous, requestedMount: mount) == nil)
    }

    @Test func planMountsReadOnlyAndReviewsOneVerifiedApplication() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let commands = DiskImageCommandHarness()

        let plan = try await AppMaintenanceDiskImageInstaller.plan(
            imageURL: fixture.image, destinationRoot: fixture.destination,
            run: { try commands.run($0) })
        #expect(plan.sourceApplication.bundleID == "com.example.installer")
        #expect(plan.sourceApplication.version == "2.0")
        #expect(
            plan.destinationURL.path
                == fixture.destination.appendingPathComponent("Example.app").path)
        let attach = try #require(commands.recordedRequests.first)
        #expect(attach.arguments.prefix(4) == ["attach", "-readonly", "-nobrowse", "-plist"])
        #expect(attach.terminatesProcessGroup)
        #expect(commands.recordedRequests.contains { $0.executableURL.path == "/usr/bin/codesign" })
        #expect(commands.recordedRequests.contains { $0.executableURL.path == "/usr/sbin/spctl" })
        await AppMaintenanceDiskImageInstaller.cancel(
            plan: plan, run: { try commands.run($0) })
    }

    @Test func planRejectsEmptyAndMultipleImagesAndEjectsThem() async throws {
        for count in [0, 2] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let commands = DiskImageCommandHarness()
            commands.applicationCount = count

            await #expect(throws: AppMaintenanceDiskImageError.singleApplicationRequired(count)) {
                _ = try await AppMaintenanceDiskImageInstaller.plan(
                    imageURL: fixture.image, destinationRoot: fixture.destination,
                    run: { try commands.run($0) })
            }
            #expect(commands.recordedRequests.contains { $0.arguments.first == "detach" })
        }
    }

    @Test func planRejectsInvalidMountSignatureAndGatekeeperAssessment() async throws {
        for failure in ["mount", "signature", "assessment"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let commands = DiskImageCommandHarness()
            commands.validAttachment = failure != "mount"
            commands.signatureStatus = failure == "signature" ? 1 : 0
            commands.assessmentStatus = failure == "assessment" ? 1 : 0
            let expected: AppMaintenanceDiskImageError =
                failure == "mount" ? .invalidMount : .verificationFailed

            await #expect(throws: expected) {
                _ = try await AppMaintenanceDiskImageInstaller.plan(
                    imageURL: fixture.image, destinationRoot: fixture.destination,
                    run: { try commands.run($0) })
            }
            #expect(commands.recordedRequests.contains { $0.arguments.first == "detach" })
        }
    }

    @Test func planAcceptsDisabledGatekeeperAfterSignatureVerification() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let commands = DiskImageCommandHarness()
        commands.assessmentsDisabled = true

        let plan = try await AppMaintenanceDiskImageInstaller.plan(
            imageURL: fixture.image, destinationRoot: fixture.destination,
            run: { try commands.run($0) })
        #expect(
            !commands.recordedRequests.contains {
                $0.executableURL.path == "/usr/sbin/spctl" && $0.arguments.first == "--assess"
            })
        await AppMaintenanceDiskImageInstaller.cancel(
            plan: plan, run: { try commands.run($0) })
    }

    @Test func destinationCollisionRequiresTheSameBundleIdentifier() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try makeInstallerApplication(
            at: fixture.destination.appendingPathComponent("Example.app"),
            bundleID: "com.example.different", version: "1.0")
        let commands = DiskImageCommandHarness()

        await #expect(throws: AppMaintenanceDiskImageError.destinationConflict) {
            _ = try await AppMaintenanceDiskImageInstaller.plan(
                imageURL: fixture.image, destinationRoot: fixture.destination,
                run: { try commands.run($0) })
        }
        #expect(commands.recordedRequests.contains { $0.arguments.first == "detach" })
    }

    @Test func installStagesReverifiesEjectsAndTrashesTheImage() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let commands = DiskImageCommandHarness()
        let trash = try DiskImageTrashHarness(
            root: fixture.root.appendingPathComponent("Trash"))
        let plan = try await AppMaintenanceDiskImageInstaller.plan(
            imageURL: fixture.image, destinationRoot: fixture.destination,
            run: { try commands.run($0) })

        let result = try await AppMaintenanceDiskImageInstaller.install(
            plan: plan, replaceExisting: false, run: { try commands.run($0) },
            trash: { try trash.move($0) })

        #expect(FileManager.default.fileExists(atPath: result.applicationURL.path))
        #expect(!result.replacedExisting)
        #expect(result.ejected)
        #expect(result.imageMovedToTrash)
        #expect(trash.items == [fixture.image])
        #expect(
            commands.recordedRequests.filter { $0.executableURL.path == "/usr/bin/codesign" }
                .count == 2)
        #expect(commands.recordedRequests.contains { $0.executableURL.path == "/usr/bin/ditto" })
    }

    @Test func replacementNeedsConfirmationAndMovesTheOldAppToTrash() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let existing = fixture.destination.appendingPathComponent("Example.app")
        try makeInstallerApplication(
            at: existing, bundleID: "com.example.installer", version: "1.0")
        let commands = DiskImageCommandHarness()
        let firstPlan = try await AppMaintenanceDiskImageInstaller.plan(
            imageURL: fixture.image, destinationRoot: fixture.destination,
            run: { try commands.run($0) })

        await #expect(throws: AppMaintenanceDiskImageError.replacementRequiresConfirmation) {
            _ = try await AppMaintenanceDiskImageInstaller.install(
                plan: firstPlan, replaceExisting: false, run: { try commands.run($0) })
        }
        #expect(FileManager.default.fileExists(atPath: existing.path))

        let secondPlan = try await AppMaintenanceDiskImageInstaller.plan(
            imageURL: fixture.image, destinationRoot: fixture.destination,
            run: { try commands.run($0) })
        let trash = try DiskImageTrashHarness(
            root: fixture.root.appendingPathComponent("Trash"))
        let result = try await AppMaintenanceDiskImageInstaller.install(
            plan: secondPlan, replaceExisting: true, moveImageToTrash: false,
            run: { try commands.run($0) }, trash: { try trash.move($0) })

        #expect(result.replacedExisting)
        #expect(result.ejected)
        #expect(!result.imageMovedToTrash)
        #expect(trash.items.map(\.path) == [existing.path])
        let installedInfo = try Data(
            contentsOf: existing.appendingPathComponent("Contents/Info.plist"))
        let installedPlist = try #require(
            PropertyListSerialization.propertyList(
                from: installedInfo, options: [], format: nil) as? [String: Any])
        #expect(installedPlist["CFBundleShortVersionString"] as? String == "2.0")
    }

    @Test func installRejectsAChangedReviewedImageAndEjects() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let commands = DiskImageCommandHarness()
        let plan = try await AppMaintenanceDiskImageInstaller.plan(
            imageURL: fixture.image, destinationRoot: fixture.destination,
            run: { try commands.run($0) })
        try FileManager.default.removeItem(at: fixture.image)
        try Data("replacement".utf8).write(to: fixture.image)

        await #expect(throws: AppMaintenanceDiskImageError.reviewedSourceChanged) {
            _ = try await AppMaintenanceDiskImageInstaller.install(
                plan: plan, replaceExisting: false, run: { try commands.run($0) })
        }
        #expect(commands.recordedRequests.last?.arguments.first == "detach")
        #expect(!FileManager.default.fileExists(atPath: plan.mountURL.path))
    }

    @Test func installRejectsAChangedDestinationRootAndEjects() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let commands = DiskImageCommandHarness()
        let plan = try await AppMaintenanceDiskImageInstaller.plan(
            imageURL: fixture.image, destinationRoot: fixture.destination,
            run: { try commands.run($0) })
        try FileManager.default.removeItem(at: fixture.destination)
        try FileManager.default.createDirectory(
            at: fixture.destination, withIntermediateDirectories: true)

        await #expect(throws: AppMaintenanceDiskImageError.reviewedDestinationChanged) {
            _ = try await AppMaintenanceDiskImageInstaller.install(
                plan: plan, replaceExisting: false, run: { try commands.run($0) })
        }
        #expect(commands.recordedRequests.last?.arguments.first == "detach")
        #expect(!FileManager.default.fileExists(atPath: plan.mountURL.path))
    }

    @Test func failedEjectKeepsTheReviewedImage() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let commands = DiskImageCommandHarness()
        commands.detachStatus = 1
        let trash = try DiskImageTrashHarness(
            root: fixture.root.appendingPathComponent("Trash"))
        let plan = try await AppMaintenanceDiskImageInstaller.plan(
            imageURL: fixture.image, destinationRoot: fixture.destination,
            run: { try commands.run($0) })

        let result = try await AppMaintenanceDiskImageInstaller.install(
            plan: plan, replaceExisting: false, run: { try commands.run($0) },
            trash: { try trash.move($0) })

        #expect(!result.ejected)
        #expect(!result.imageMovedToTrash)
        #expect(FileManager.default.fileExists(atPath: fixture.image.path))
        #expect(trash.items.isEmpty)
        commands.detachStatus = 0
        await AppMaintenanceDiskImageInstaller.cancel(
            plan: plan, run: { try commands.run($0) })
    }

    private func fixture() throws -> (root: URL, image: URL, destination: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("Example.dmg")
        try Data("disk image".utf8).write(to: image)
        return (root, image, destination)
    }

    private func attachmentData(_ entities: [[String: String]]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["system-entities": entities], format: .xml, options: 0)
    }
}

private func makeInstallerApplication(
    at url: URL, bundleID: String, version: String
) throws {
    let contents = url.appendingPathComponent("Contents", isDirectory: true)
    let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(
        at: executableDirectory, withIntermediateDirectories: true)
    let executable = executableDirectory.appendingPathComponent("Example")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let plist: [String: Any] = [
        "CFBundleExecutable": "Example",
        "CFBundleIdentifier": bundleID,
        "CFBundleName": "Example",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
}
