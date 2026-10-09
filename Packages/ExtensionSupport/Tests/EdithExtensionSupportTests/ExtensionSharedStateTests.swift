import Darwin
import Foundation
import Testing
@testable import EdithExtensionSupport

@Suite final class ExtensionSharedStateTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func stateIsScopedToItsOwnerAndApplication() throws {
        let first = ExtensionSharedState(
            root: root.appendingPathComponent("first"), namespace: "fixture.first",
            owner: "presenter")
        let second = ExtensionSharedState(
            root: root.appendingPathComponent("second"), namespace: "fixture.second",
            owner: "presenter")
        try first.publish(["active": "1"])
        #expect(first.values(for: "presenter") == ["active": "1"])
        #expect(first.values(for: "calendar").isEmpty)
        #expect(second.values(for: "presenter").isEmpty)
        #expect(first.notificationName != second.notificationName)
        try first.clear("presenter")
        #expect(first.values(for: "presenter").isEmpty)
    }

    @Test func exitedAndReusedProcessesCannotSupplyStaleState() throws {
        let state = ExtensionSharedState(root: root, namespace: "fixture", owner: "presenter")
        try state.publish(["active": "1"])
        let file = root.appendingPathComponent("presenter.json")
        var snapshot =
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        snapshot["generation"] = "invalid"
        try JSONSerialization.data(withJSONObject: snapshot).write(to: file)
        #expect(state.values(for: "presenter").isEmpty)
        snapshot["pid"] = Int32.max
        try JSONSerialization.data(withJSONObject: snapshot).write(to: file)
        #expect(state.values(for: "presenter").isEmpty)
    }

    @Test func unsafeOwnersAndOversizedStateCannotBePublishedOrRead() throws {
        for owner in ["../outside", ".hidden", "", "a/b"] {
            let state = ExtensionSharedState(root: root, namespace: "fixture", owner: owner)
            #expect(throws: (any Error).self) { try state.publish(["active": "1"]) }
            #expect(state.values(for: owner).isEmpty)
            #expect(throws: (any Error).self) { try state.clear(owner) }
        }
        let state = ExtensionSharedState(root: root, namespace: "fixture", owner: "presenter")
        #expect(throws: (any Error).self) {
            try state.publish(["value": String(repeating: "x", count: 65_536)])
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 65_537).write(
            to: root.appendingPathComponent("presenter.json"))
        #expect(state.values(for: "presenter").isEmpty)
    }

    @Test func readOnlyClientsCannotPublish() {
        let state = ExtensionSharedState(root: root, namespace: "fixture")
        #expect(throws: (any Error).self) { try state.publish(["active": "1"]) }
    }
}
