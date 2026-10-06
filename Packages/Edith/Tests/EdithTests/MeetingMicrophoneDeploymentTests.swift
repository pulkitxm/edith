import EdithLidAwakeSupport
import Foundation
import Testing

struct MeetingMicrophoneDeploymentTests {
    @Test func deploymentUsesBundledComponentAndReplacesOnlyWhenChanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appendingPathComponent("Edith.app")
        let source = application.appendingPathComponent(MeetingMicrophoneDeployment.relativePath)
        let destination = root.appendingPathComponent("HAL")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let content = source.appendingPathComponent("version")
        try Data("first".utf8).write(to: content)
        let verify: (URL) throws -> Data = {
            try Data(contentsOf: $0.appendingPathComponent("version"))
        }
        #expect(
            try MeetingMicrophoneDeployment.synchronize(
                application: application, destination: destination, verify: verify))
        #expect(
            try !MeetingMicrophoneDeployment.synchronize(
                application: application, destination: destination, verify: verify))
        try Data("second".utf8).write(to: content)
        #expect(
            try MeetingMicrophoneDeployment.synchronize(
                application: application, destination: destination, verify: verify))
        let installed = destination.appendingPathComponent(
            MeetingMicrophoneDeployment.identifier + ".driver")
        #expect(try verify(installed) == Data("second".utf8))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: destination.path) == [
                installed.lastPathComponent
            ])
    }

    @Test func rejectedStagingLeavesInstalledComponentIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appendingPathComponent("Edith.app")
        let source = application.appendingPathComponent(MeetingMicrophoneDeployment.relativePath)
        let destination = root.appendingPathComponent("HAL")
        let installed = destination.appendingPathComponent(
            MeetingMicrophoneDeployment.identifier + ".driver")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: installed.appendingPathComponent("version"))
        #expect(throws: (any Error).self) {
            try MeetingMicrophoneDeployment.synchronize(
                application: application, destination: destination
            ) { url in
                if url == source { return Data("new".utf8) }
                if url == installed { return Data("existing".utf8) }
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        #expect(
            try Data(contentsOf: installed.appendingPathComponent("version"))
                == Data("existing".utf8))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: destination.path) == [
                installed.lastPathComponent
            ])
    }

    @Test func rejectsRedirectedComponentPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appendingPathComponent("Edith.app")
        let source = application.appendingPathComponent(MeetingMicrophoneDeployment.relativePath)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try MeetingMicrophoneDeployment.synchronize(
                application: application, destination: root.appendingPathComponent("HAL")
            ) { _ in
                Data("unreachable".utf8)
            }
        }
    }
}
