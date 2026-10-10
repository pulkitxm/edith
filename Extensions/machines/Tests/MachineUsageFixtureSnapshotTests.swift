import Foundation
import Testing
@testable import MachinesExtension

@Suite struct MachineUsageFixtureSnapshotTests {
    @Test func onlyOwnedBoundedRegularRawSnapshotsAreAccepted() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["EDITH_EXTENSION_FIXTURE_HOME": home.path]
        let file = home.appendingPathComponent("machines-raw-snapshot.json")
        #expect(throws: (any Error).self) {
            try MachineUsageFixtureSnapshot.load(environment: environment)
        }
        let data = Data("{\"version\":1,\"files\":[],\"context\":{\"projects\":[]}}".utf8)
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try MachineUsageFixtureSnapshot.load(environment: environment) == data)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) {
            try MachineUsageFixtureSnapshot.load(environment: environment)
        }
        try FileManager.default.removeItem(at: file)
        let target = home.appendingPathComponent("target.json")
        try data.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try MachineUsageFixtureSnapshot.load(environment: environment)
        }
        try FileManager.default.removeItem(at: file)
        try Data("{\"schemaVersion\":8}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) {
            try MachineUsageFixtureSnapshot.load(environment: environment)
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 67_108_865)
        try handle.close()
        #expect(throws: (any Error).self) {
            try MachineUsageFixtureSnapshot.load(environment: environment)
        }
        #expect(throws: (any Error).self) { try MachineUsageFixtureSnapshot.load(environment: [:]) }
        #expect(throws: (any Error).self) {
            try MachineUsageFixtureSnapshot.load(environment: [
                "EDITH_EXTENSION_FIXTURE_HOME": NSHomeDirectory()
            ])
        }
    }
}
