import Darwin
import Foundation
import Testing

@testable import Edith

struct DevelopmentAgentJobTests {
    @Test func launchPlistIsOwnedPrivateAndRefreshedFromTheBundle() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.worker.plist")
        let directory = root.appendingPathComponent("runtime/launch-agents")
        for program in ["/sample/first/worker", "/sample/second/worker"] {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["Label": "sample.worker", "ProgramArguments": [program]],
                format: .xml, options: 0)
            try data.write(to: source)
            let destination = try DevelopmentAgentJob.prepareLaunchPlist(
                source: source, directory: directory)
            #expect(destination == directory.appendingPathComponent(source.lastPathComponent))
            #expect(try Data(contentsOf: destination) == data)
            let attributes = try manager.attributesOfItem(atPath: destination.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        }
    }

    @Test func missingBundlePlistCannotProduceAJob() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("missing.plist")
        let directory = root.appendingPathComponent("runtime")
        #expect(throws: (any Error).self) {
            try DevelopmentAgentJob.prepareLaunchPlist(source: source, directory: directory)
        }
        #expect(!manager.fileExists(atPath: directory.path))
    }
}
