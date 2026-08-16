import Foundation
import Testing

@testable import EdithKit

@Suite struct CompanionRuntimeFilesTests {
    static let companionDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("apps/companion")

    @Test func theEmbeddedRuntimeFilesMatchTheRepo() throws {
        for file in CompanionRuntimeFiles.all {
            let onDisk = try String(
                contentsOf: Self.companionDir.appendingPathComponent(file.name),
                encoding: .utf8)
            #expect(
                file.content == onDisk,
                "\(file.name) drifted; regenerate CompanionRuntimeFiles from apps/companion")
        }
    }

    @Test func everyServiceComesBackAfterAReboot() {
        let sections = CompanionRuntimeFiles.composeBase.components(separatedBy: "  image:")
        let services =
            CompanionRuntimeFiles.composeBase
            .components(separatedBy: "restart: unless-stopped").count - 1
        #expect(services == 5, "all five services need a restart policy")
        #expect(sections.count > 1)
    }
}

@Suite struct CompanionEndpointTests {
    @Test func theEndpointFollowsTheDeploymentRecord() async throws {
        await CLIProbe.inWorld { _ in
            #expect(
                CompanionClient.endpoint(override: nil).absoluteString
                    == "http://127.0.0.1:4820")
            _ = CompanionDeploymentStore.save(
                CompanionDeployment(
                    machineID: UUID(), machineName: "box", tier: "cpu", localPort: 14821))
            #expect(
                CompanionClient.endpoint(override: nil).absoluteString
                    == "http://127.0.0.1:14821")
            #expect(
                CompanionClient.endpoint(override: "http://10.0.0.9:4820").absoluteString
                    == "http://10.0.0.9:4820")
        }
    }
}

@Suite struct CompanionSourceTests {
    @Test func theRepoCheckoutIsLocatableThroughTheEnvironment() {
        let source = CompanionRuntimeFilesTests.companionDir
        #expect(
            FileManager.default.fileExists(
                atPath: source.appendingPathComponent("Cargo.toml").path))
    }

    @Test func theTarballPacksTheSourceWithoutTargetOrGit() throws {
        let data = try CompanionSource.tarball(of: CompanionRuntimeFilesTests.companionDir)
        #expect(data.count > 10_000)
        let listing = try list(data)
        #expect(listing.contains("./Cargo.toml"))
        #expect(listing.contains("./src/main.rs"))
        #expect(!listing.contains("./target/"))
        #expect(!listing.contains("./.git/"))
    }

    private func list(_ tarball: Data) throws -> String {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-tar-\(UUID().uuidString).tgz")
        try tarball.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tzf", temp.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
